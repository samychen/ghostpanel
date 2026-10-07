import 'package:flutter_test/flutter_test.dart';
import 'package:ghostpanel/services/command_guard.dart';

/// 危险命令拦截规则测试 —— 对应方案文档 §6.3.3 黑名单 与 §4.2 GUI 命令提示。
void main() {
  group('CommandGuard.danger（应拦截）', () {
    final dangerous = [
      'reboot',
      'shutdown -h now',
      'sudo poweroff',
      'halt',
      'rm -rf /',
      'rm -fr /*',
      'sudo rm -rf /',
      'rm -r -f ~',
      'rm --no-preserve-root -rf /',
      'dd if=/dev/zero of=/dev/sda',
      'sudo dd if=/dev/urandom of=/dev/nvme0n1',
      'mkfs.ext4 /dev/sdb1',
      'sudo mkfs /dev/sdc',
      'killall Xorg',
      'killall gnome-shell',
      'sudo pkill -f gnome-shell',
      'systemctl stop gdm',
      'systemctl stop gdm3',
      'sudo systemctl isolate multi-user.target',
      'loginctl terminate-user bob',
      'chmod -R 777 /etc',
      'sudo chown -R nobody /usr',
      ':(){ :|:& };:',
      'init 0',
      'wipefs -a /dev/sda',
    ];
    for (final cmd in dangerous) {
      test('拦截: $cmd', () {
        expect(CommandGuard.check(cmd).isDanger, isTrue, reason: cmd);
      });
    }
  });

  group('CommandGuard.notice（零打扰警告但放行）', () {
    final disturbing = [
      'notify-send "Hello"',
      'zenity --info --text="Hi"',
      'xdg-open file.pdf',
      'gedit file.txt',
      'nautilus /some/path',
      'DISPLAY=:0 myapp',
      'xdotool key ctrl+s',
      'xclip -o',
      'wall "维护通知"',
      'paplay alert.wav',
    ];
    for (final cmd in disturbing) {
      test('警告: $cmd', () {
        expect(CommandGuard.check(cmd).isNotice, isTrue, reason: cmd);
      });
    }
  });

  group('CommandGuard.ok（正常放行）', () {
    final safe = [
      'nvidia-smi',
      'ls -la /var/log',
      'sudo systemctl restart nginx',
      'sudo systemctl status docker',
      'tmux new -s work',
      'tmux ls',
      'make -j4',
      'ffmpeg -i input.mp4 output.mp4',
      'cat file.txt',
      'rsync -av --bwlimit=8M ~/data/ /mnt/nas/',
      'nice -n 19 ionice -c3 tar czf backup.tgz ~/project',
      'journalctl -u nginx --since "10 min ago"',
      'rm -rf build/',
      'rm file.txt',
      'kill 12345',
      'systemctl restart docker',
      'python3 train.py --epochs 10',
      'xvfb-run -a my_gui_program',
      'df -h && free -h',
    ];
    for (final cmd in safe) {
      test('放行: $cmd', () {
        expect(CommandGuard.check(cmd).isOk, isTrue, reason: cmd);
      });
    }
  });

  test('拦截结果包含原因与建议', () {
    final v = CommandGuard.check('sudo rm -rf /');
    expect(v.isDanger, isTrue);
    expect(v.reason, isNotEmpty);
    expect(v.advice, isNotEmpty);
  });

  test('空命令放行', () {
    expect(CommandGuard.check('').isOk, isTrue);
    expect(CommandGuard.check('   ').isOk, isTrue);
  });
}
