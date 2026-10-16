#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Encode qw(encode decode);
use Getopt::Long qw(GetOptions);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempfile tempdir);
use File::Basename qw(dirname);
use Fcntl qw(:DEFAULT :flock);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use IO::Socket::INET;
use IO::Select;
use IO::Handle;
use IPC::Open3;
use Symbol qw(gensym);
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
binmode STDIN, ':encoding(UTF-8)';
umask 0077;
my $JSON = JSON::PP->new->utf8->canonical->pretty;
my $lock_owned;
my @temps;
END {
    unlink $_ for grep { defined && -f $_ } @temps;
    if ($lock_owned) { unlink "$lock_owned/owner.txt"; rmdir $lock_owned; }
}

sub fail { die encode('UTF-8', $_[0] . "\n"); }
sub now { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime); }
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or fail("无法读取 $path：$!");
    local $/; my $data = <$fh>;
    close $fh or fail("读取文件失败：$!");
    return defined($data) ? $data : '';
}
sub no_link {
    for my $path (@_) { fail("为避免改到其他位置，拒绝符号链接：$path") if -l $path; }
}
sub snapshot {
    my ($home) = @_;
    my $env = "$home/.env";
    no_link($home, $env);
    fail("配置路径不是目录：$home") if -e $home && !-d $home;
    fail("目标不是普通文件：$env") if -e $env && !-f $env;
    return {existed => JSON::PP::false, bytes => '', sha => undef, mode => 0600} if !-e $env;
    my $data = slurp($env);
    return {existed => JSON::PP::true, bytes => $data, sha => sha256_hex($data), mode => (stat($env))[2] & 0777};
}
sub same_snapshot {
    my ($a, $b) = @_;
    return !!$a->{existed} == !!$b->{existed} && (!$a->{existed} || $a->{sha} eq $b->{sha});
}
sub lock_home {
    my ($home) = @_;
    no_link($home, "$home/proxy-helper-backups", "$home/proxy-helper.lock");
    make_path($home, {mode => 0700}) if !-d $home;
    mkdir "$home/proxy-helper.lock", 0700
        or fail('另一个配置操作正在进行，或上次异常退出留下了 proxy-helper.lock；请确认没有工具运行后再清理该锁目录。');
    $lock_owned = "$home/proxy-helper.lock";
    write_new("$lock_owned/owner.txt", "pid=$$\ntime=" . now() . "\n", 0600);
}
sub unlock_home {
    return unless $lock_owned;
    unlink "$lock_owned/owner.txt";
    rmdir $lock_owned or fail('无法移除操作锁，请检查配置目录权限。');
    $lock_owned = undef;
}
sub write_new {
    my ($path, $bytes, $mode) = @_;
    sysopen my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, $mode
        or fail("无法创建 $path：$!");
    binmode $fh, ':raw';
    print {$fh} $bytes or fail("无法写入 $path：$!");
    $fh->flush or fail("无法刷新 $path：$!");
    $fh->sync or fail("无法同步 $path：$!");
    close $fh or fail("无法关闭 $path：$!");
}
sub prepare_atomic {
    my ($path, $bytes, $mode) = @_;
    no_link($path, dirname($path));
    my ($fh, $tmp) = tempfile('.codex-proxy-XXXXXX', DIR => dirname($path), UNLINK => 0);
    push @temps, $tmp;
    binmode $fh, ':raw';
    chmod $mode, $tmp or fail("无法设置文件权限：$!");
    print {$fh} $bytes or fail("无法写入临时文件：$!");
    $fh->flush or fail("无法刷新临时文件：$!");
    $fh->sync or fail("无法同步临时文件：$!");
    close $fh or fail("无法关闭临时文件：$!");
    return $tmp;
}
sub replace_file {
    my ($tmp, $path) = @_;
    no_link($path);
    rename $tmp, $path or fail("无法原子替换 $path：$!");
}
sub render_env {
    my ($data, $port) = @_;
    fail('现有 .env 包含 NUL 字节或 UTF-16 编码；macOS 版本不会编辑该格式，请先转换为 UTF-8。原文件未修改。') if index($data, "\0") >= 0;
    my $bom = $data =~ s/\A\xEF\xBB\xBF// ? "\xEF\xBB\xBF" : '';
    my ($eol) = $data =~ /(\r\n|\r|\n)/;
    $eol = "\n" if !defined($eol);
    my ($quote, $drop, $kept) = ('', 0, '');
    for my $line ($data =~ /[^\r\n]*(?:\r\n|\r|\n|\z)/g) {
        next if !length($line);
        my $tail = $line;
        if (!$quote) {
            $drop = 0;
            if ($line =~ /\A[\t ]*(?:export[\t ]+)?([A-Za-z_][A-Za-z0-9_]*)[\t ]*=[\t ]*(.*)/s) {
                my ($key, $value) = ($1, $2);
                $drop = $key =~ /\A(?:HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\z/i;
                if ($value =~ /\A(['"])(.*)/s) { ($quote, $tail) = ($1, $2); }
            }
        }
        if ($quote) {
            for (my $i = 0; $i < length($tail); $i++) {
                my $char = substr($tail, $i, 1);
                if ($char eq '\\') { $i++; next; }
                if ($char eq $quote) { $quote = ''; last; }
            }
        }
        $kept .= $line unless $drop;
    }
    fail('现有 .env 存在未闭合的引号，已停止以保留原文件。') if $quote;
    $data = $kept;
    $data .= $eol if length($data) && $data !~ /[\r\n]\z/;
    $data .= join($eol, "HTTP_PROXY=http://127.0.0.1:$port", "HTTPS_PROXY=http://127.0.0.1:$port", 'NO_PROXY=localhost,127.0.0.1,::1') . $eol;
    return $bom . $data;
}
sub valid_port {
    my ($port) = @_;
    fail('端口应为 1 到 65535 的整数。') unless defined($port) && $port =~ /\A[0-9]{1,5}\z/ && $port > 0 && $port <= 65535;
    return 0 + $port;
}
sub probe {
    my ($port) = @_;
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1);
    return 'closed' unless $sock;
    $sock->autoflush(1);
    local $SIG{PIPE} = 'IGNORE';
    my $sent = print {$sock} "CONNECT chatgpt.com:443 HTTP/1.1\r\nHost: chatgpt.com:443\r\n\r\n";
    if (!$sent) { close $sock; return 'non-http'; }
    my $select = IO::Select->new($sock);
    my $line = '';
    my $deadline = Time::HiRes::time() + 2;
    while (length($line) < 2048 && $line !~ /\n/) {
        my $left = $deadline - Time::HiRes::time();
        last if $left <= 0 || !$select->can_read($left);
        my $n = sysread($sock, my $chunk, 512);
        last unless $n;
        $line .= $chunk;
    }
    close $sock;
    return 'http' if $line =~ /\AHTTP\/1\.[01][\t ]+200[\t ]+[^\r\n]*\r?\n/;
    return 'auth' if $line =~ /\AHTTP\/1\.[01][\t ]+407[\t ]/;
    return 'non-http';
}
sub candidate_ports {
    my @ports = (7897, 7890, 7899, 10809, 10808, 1080, 8080, 8888, 2080, 20171, 6152);
    if (open my $ps, '-|', '/bin/ps', '-axo', 'pid=,comm=') {
        while (<$ps>) {
            if (/^\s*(\d+)\s+.*(?:clash|mihomo|v2ray|xray|sing-box|surge|stash|shadowrocket|qv2ray)/i) {
                my $pid = $1;
                if (open my $ls, '-|', '/usr/sbin/lsof', '-nP', '-a', '-p', $pid, '-iTCP', '-sTCP:LISTEN', '-Fn') {
                    while (<$ls>) { push @ports, $1 if /^n(?:127\.0\.0\.1|\*|\[::1\]):(\d+)$/; }
                    close $ls;
                }
            }
        }
        close $ps;
    }
    my %seen;
    return grep { $_ > 0 && $_ <= 65535 && !$seen{$_}++ } @ports;
}
sub detect_ports {
    print "正在检测本机 HTTP / 混合代理端口…\n";
    my @ports = candidate_ports();
    splice(@ports, 48) if @ports > 48;
    my $scratch = tempdir('codex-proxy-probe-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my @children;
    for my $port (@ports) {
        my $pid = fork();
        if (!defined $pid) { next; }
        if (!$pid) {
            # Child must not own the parent transaction lock or temporary files.
            $lock_owned = undef; @temps = ();
            my $result = probe($port);
            write_new("$scratch/$port", $result, 0600);
            POSIX::_exit(0);
        }
        push @children, $pid;
    }
    waitpid($_, 0) for @children;
    my @working;
    for my $port (@ports) {
        next unless -f "$scratch/$port";
        my $result = slurp("$scratch/$port");
        if ($result eq 'http') { push @working, $port; print "  $port  HTTP CONNECT 通过\n"; }
        elsif ($result eq 'auth') { print "  $port  需要代理认证，未选用\n"; }
        elsif ($result ne 'closed') { print "  $port  TCP 开放，未通过 HTTP CONNECT\n"; }
    }
    print "没有发现可用 HTTP 代理。请启动代理软件，或手动指定 HTTP / 混合端口。\n" if !@working;
    return @working;
}
sub preview_text {
    my ($home, $port, $exists) = @_;
    return "目标文件：$home/.env\n\nHTTP_PROXY=http://127.0.0.1:$port\nHTTPS_PROXY=http://127.0.0.1:$port\nNO_PROXY=localhost,127.0.0.1,::1\n\n" .
        ($exists ? '写入前会备份原文件，保留其他配置。' : '原文件不存在；恢复时会删除本次新建的文件。');
}
sub osa {
    my ($script, @args) = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, '/usr/bin/osascript', '-', map { encode('UTF-8', $_) } @args);
    binmode $in, ':raw'; print {$in} encode('UTF-8', $script); close $in;
    local $/;
    my $text = <$out> // ''; my $error = <$err> // '';
    waitpid($pid, 0);
    if ($? != 0) {
        return undef if $error =~ /\(-128\)/;
        fail('无法打开 macOS 原生界面，可使用 --cli 命令行模式。' . decode('UTF-8', $error));
    }
    my $value = decode('UTF-8', $text); $value =~ s/\r?\n\z//;
    return $value;
}
sub dialog {
    my ($text) = @_;
    osa('on run argv
display dialog (item 1 of argv) with title "Codex 代理助手" buttons {"好"} default button "好"
end run', $text);
}
sub confirm {
    my ($text, $yes, $gui) = @_;
    return 1 if $yes;
    if ($gui) {
        my $answer = osa('on run argv
set answer to display dialog (item 1 of argv) with title "确认修改" buttons {"取消", "确认"} default button "确认" cancel button "取消"
return button returned of answer
end run', $text);
        return defined($answer) && $answer eq '确认';
    }
    print "输入“确认”或 yes 继续，其他输入取消：";
    my $answer = <STDIN> // ''; $answer =~ s/\s+\z//;
    return $answer eq '确认' || lc($answer) eq 'yes';
}
sub choose_port {
    my ($gui) = @_;
    my @ports = detect_ports();
    if ($gui) {
        my @options = ((map { "$_ — HTTP CONNECT 通过" } @ports), '手动输入端口');
        my $choice = osa('on run argv
set answer to choose from list (items 2 thru -1 of argv) with title "选择本地代理" with prompt (item 1 of argv) default items {item 2 of argv}
if answer is false then return ""
return item 1 of answer
end run', '选择代理的 HTTP / 混合端口。', @options);
        return undef unless defined($choice) && length($choice);
        return 0 + $1 if $choice =~ /\A(\d+) —/;
        my $typed = osa('on run argv
set answer to display dialog "输入 HTTP / 混合端口（例如 7897）" with title "手动指定端口" default answer "7897" buttons {"取消", "继续"} default button "继续" cancel button "取消"
return text returned of answer
end run');
        return defined($typed) ? valid_port($typed) : undef;
    }
    fail('未找到可用代理。可使用 --port 7897 手动指定。') if !@ports;
    print "发现多个可用端口，默认使用 $ports[0]；可用 --port 指定其他端口。\n" if @ports > 1;
    return $ports[0];
}
sub apply_proxy {
    my ($home, $port, $yes, $gui, $preview) = @_;
    $port = valid_port($port);
    my $result = probe($port);
    fail("127.0.0.1:$port 未通过 HTTP CONNECT 检测；请确认代理已启动，并使用 HTTP / 混合端口。") if $result ne 'http';
    my $before = snapshot($home);
    my $after = render_env($before->{bytes}, $port);
    my $text = preview_text($home, $port, $before->{existed});
    print "$text\n";
    if ($preview) { return '仅预览，没有写入文件。'; }
    if ($before->{existed} && $before->{bytes} eq $after) { return '配置已是所选代理，无需重复写入。'; }
    return '已取消，没有写入文件。' unless confirm($text, $yes, $gui);
    lock_home($home);
    my $fresh = snapshot($home);
    fail('预览后 .env 发生变化，已取消写入。请重新预览。') unless same_snapshot($before, $fresh);
    no_link("$home/proxy-helper-backups");
    make_path("$home/proxy-helper-backups", {mode => 0700});
    my ($sec, $usec) = gettimeofday();
    my $name = strftime('%Y%m%dT%H%M%S', gmtime($sec)) . sprintf('%03d-%06x', int($usec / 1000), int(rand(0xFFFFFF)));
    my $backup = "$home/proxy-helper-backups/$name";
    mkdir $backup, 0700 or fail("无法创建备份目录：$!");
    write_new("$backup/original.env", $before->{bytes}, 0600) if $before->{existed};
    my $manifest = {schema => 1, state => 'pending', existed => $before->{existed}, before_sha256 => $before->{sha}, after_sha256 => sha256_hex($after), created_at => now(), mode_unix => $before->{mode}};
    write_new("$backup/manifest.json", $JSON->encode($manifest), 0600);
    fail('备份校验失败，未修改 .env。') if $before->{existed} && sha256_hex(slurp("$backup/original.env")) ne $before->{sha};
    my $tmp = prepare_atomic("$home/.env", $after, $before->{mode});
    fail('写入前 .env 发生变化，已取消。') unless same_snapshot($before, snapshot($home));
    replace_file($tmp, "$home/.env");
    fail('写入后校验失败，请使用备份恢复。') unless sha256_hex(slurp("$home/.env")) eq $manifest->{after_sha256};
    $manifest->{state} = 'applied';
    $manifest->{applied_at} = now();
    replace_file(prepare_atomic("$backup/manifest.json", $JSON->encode($manifest), 0600), "$backup/manifest.json");
    unlock_home();
    return "代理配置已写入并核对。\n备份：$backup\n\n请等待其他任务结束，用 ⌘Q 完全退出 Codex 所在应用，再打开并用新任务发消息验证。\n检测通过仅表示本次 CONNECT 被接受，重连是否解决仍需实测。";
}
sub read_manifest {
    my ($path) = @_;
    no_link(dirname($path), $path);
    my $raw = slurp($path); my $json = $raw; $json =~ s/\A\xEF\xBB\xBF//;
    my $m = eval { $JSON->decode($json) };
    fail("备份清单损坏：$path") unless ref($m) eq 'HASH' && ($m->{schema} // 0) == 1 && defined($m->{existed}) && ($m->{after_sha256} // '') =~ /\A[0-9a-f]{64}\z/;
    fail("备份清单缺少原文件校验值：$path") if $m->{existed} && ($m->{before_sha256} // '') !~ /\A[0-9a-f]{64}\z/;
    return ($m, $raw);
}
sub restore_proxy {
    my ($home, $yes, $gui) = @_;
    my $initial = snapshot($home);
    my $base = "$home/proxy-helper-backups";
    no_link($base);
    fail('没有本工具创建的备份；未修改任何文件。') unless -d $base;
    opendir my $dh, $base or fail("无法读取备份目录：$!");
    my @names = sort {$b cmp $a} grep { /\A\d{8}T\d{9}-[0-9a-f]+\z/ } readdir($dh);
    closedir $dh;
    my ($chosen, $manifest, $raw);
    for my $name (@names) {
        my $path = "$base/$name/manifest.json";
        next unless -e $path || -l $path;
        my ($m, $bytes) = read_manifest($path);
        if (($m->{state} // 'applied') eq 'pending') {
            my $matches_before = !!$initial->{existed} == !!$m->{existed} && (!$m->{existed} || $initial->{sha} eq $m->{before_sha256});
            next if $matches_before && !-e "$base/$name/manifest.before-restore.json";
        }
        if (!$m->{restored_at}) { ($chosen, $manifest, $raw) = ("$base/$name", $m, $bytes); last; }
    }
    fail('没有尚未恢复的配置记录；未修改任何文件。') unless $chosen;
    my $text = "目标文件：$home/.env\n备份：$chosen\n\n" . ($manifest->{existed} ? '恢复为该次修改前的完整原文件。' : '删除该次修改新建的 .env，恢复为原先不存在的状态。');
    print "$text\n";
    return '已取消，没有修改文件。' unless confirm($text, $yes, $gui);
    lock_home($home);
    my ($current_m, $current_raw) = read_manifest("$chosen/manifest.json");
    fail('备份记录已变化，已取消恢复。') if $current_raw ne $raw;
    my $current = snapshot($home);
    my $matches_before = !!$current->{existed} == !!$manifest->{existed} && (!$manifest->{existed} || $current->{sha} eq $manifest->{before_sha256});
    my $already_restored = 0;
    if ($matches_before && -e "$chosen/manifest.before-restore.json") {
        no_link("$chosen/manifest.before-restore.json");
        $already_restored = slurp("$chosen/manifest.before-restore.json") eq $raw;
    }
    fail('当前 .env 在配置后又被修改，已停止恢复以保留后续改动。请查看备份并手动合并。') unless $already_restored || ($current->{existed} && $current->{sha} eq $manifest->{after_sha256});
    my $original;
    if ($manifest->{existed}) {
        no_link("$chosen/original.env");
        $original = slurp("$chosen/original.env");
        fail('原文件备份校验失败，未恢复。') unless sha256_hex($original) eq $manifest->{before_sha256};
    }
    if (!-e "$chosen/manifest.before-restore.json") { write_new("$chosen/manifest.before-restore.json", $raw, 0600); }
    else { no_link("$chosen/manifest.before-restore.json"); fail('恢复前清单备份不匹配。') unless slurp("$chosen/manifest.before-restore.json") eq $raw; }
    $manifest->{restored_at} = now();
    my $meta_tmp = prepare_atomic("$chosen/manifest.json", $JSON->encode($manifest), 0600);
    my $env_tmp;
    if ($manifest->{existed} && !$already_restored) {
        my $mode = defined($manifest->{mode_unix}) && $manifest->{mode_unix} =~ /\A\d+\z/ ? $manifest->{mode_unix} & 0777 : 0600;
        $env_tmp = prepare_atomic("$home/.env", $original, $mode);
    }
    fail('恢复前 .env 发生变化，已取消。') unless same_snapshot($current, snapshot($home));
    if (!$already_restored) {
        if ($manifest->{existed}) { replace_file($env_tmp, "$home/.env"); }
        else { unlink "$home/.env" or fail("无法删除本工具创建的 .env：$!"); }
    }
    replace_file($meta_tmp, "$chosen/manifest.json");
    if ($manifest->{existed}) { fail('恢复后校验失败。') unless sha256_hex(slurp("$home/.env")) eq $manifest->{before_sha256}; }
    else { fail('恢复后校验失败。') if -e "$home/.env"; }
    unlock_home();
    return '已恢复该次修改前的状态。请完全退出并重新打开 Codex 所在应用。';
}
sub run_gui {
    my ($home) = @_;
    while (1) {
        my $choice = osa('on run argv
set answer to choose from list {"检测并配置代理", "恢复上次修改", "退出"} with title "Codex 代理助手" with prompt "只维护 Codex 的代理配置。写入前先预览，并自动备份。" default items {"检测并配置代理"}
if answer is false then return "退出"
return item 1 of answer
end run');
        last if !defined($choice) || $choice eq '退出';
        my $ok = eval {
            if ($choice eq '恢复上次修改') { dialog(restore_proxy($home, 0, 1)); }
            else { my $port = choose_port(1); dialog(apply_proxy($home, $port, 0, 1, 0)) if defined $port; }
            1;
        };
        if (!$ok) { my $err = decode('UTF-8', $@); unlock_home(); dialog("操作未完成：\n$err"); }
    }
}
sub main {
    my $gui = @ARGV == 0;
    @ARGV = map { decode('UTF-8', $_) } @ARGV;
    Getopt::Long::Configure('no_auto_abbrev', 'no_ignore_case');
    my ($detect, $preview, $apply, $restore, $cli, $yes, $help, $port, $custom, $gui_requested);
    GetOptions('detect' => \$detect, 'preview' => \$preview, 'apply' => \$apply, 'restore' => \$restore, 'cli' => \$cli, 'gui' => \$gui_requested, 'yes' => \$yes, 'help' => \$help, 'port=s' => \$port, 'config-home=s' => \$custom)
        or fail('参数无效。使用 --help 查看用法。');
    fail('有无法识别的参数。使用 --help 查看用法。') if @ARGV;
    if ($help) {
        print "Codex 代理助手（macOS，无需安装额外运行时）\n\n双击 Start-macOS.command：打开简单界面\nzsh ./Start-macOS.command --cli：自动检测、预览并等待确认\nzsh ./Start-macOS.command --cli --yes：自动检测并应用（明确授权跳过确认）\nzsh ./Start-macOS.command --apply --port 7897 --yes：使用指定端口\nzsh ./Start-macOS.command --preview --port 7897：只预览\nzsh ./Start-macOS.command --detect：只检测\nzsh ./Start-macOS.command --restore：预览并恢复上次修改\n--config-home PATH：指定配置目录；默认 CODEX_HOME 或 ~/.codex\n\n只修改 .env 与本工具的备份；不会改变系统代理或其他软件设置。\n";
        return;
    }
    fail('--detect、--preview、--apply、--restore 只能选择一个。') if ($detect || 0) + ($preview || 0) + ($apply || 0) + ($restore || 0) > 1;
    fail('--restore / --detect 不接受 --port。') if defined($port) && ($restore || $detect);
    my $home = defined($custom) ? $custom : (length($ENV{CODEX_HOME} // '') ? decode('UTF-8', $ENV{CODEX_HOME}) : decode('UTF-8', $ENV{HOME}) . '/.codex');
    $home =~ s{\A~(?=/|\z)}{decode('UTF-8', $ENV{HOME})}e;
    $home = File::Spec->rel2abs($home); $home =~ s{/+\z}{};
    fail('请指定有效的 Codex 配置目录。') if !length($home) || $home eq '/';
    $gui ||= $gui_requested;
    fail('--gui 不可与其他动作或 --port、--yes 混用。') if $gui_requested && ($detect || $preview || $apply || $restore || $cli || $yes || defined($port));
    if ($gui) { run_gui($home); return; }
    if ($detect) { my @found = detect_ports(); exit(@found ? 0 : 2); }
    if ($restore) { print restore_proxy($home, $yes, 0) . "\n"; return; }
    $port = choose_port(0) unless defined($port);
    print apply_proxy($home, $port, $yes, 0, $preview) . "\n";
}
my $ok = eval { main(); 1; };
if (!$ok) { print STDERR decode('UTF-8', $@); exit 1; }
