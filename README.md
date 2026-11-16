# bt-dualboot-sync

**Stop re-pairing Bluetooth headsets, mice, and keyboards every time you switch between Windows and Ubuntu.**
**듀얼 부팅(Windows + Ubuntu/Linux)에서 OS를 바꿀 때마다 블루투스 기기를 다시 페어링하지 않게 해 주는 도구입니다.**

[English](#english) · [한국어](#한국어)

---

## 한국어

### 왜 매번 다시 연결해야 할까?

블루투스 기기를 페어링하면 PC와 기기가 비밀 **링크 키(link key)** 를 하나 정합니다.
그런데 Windows와 Linux는 같은 블루투스 칩(같은 MAC 주소)을 쓰면서 키는 각자 따로 저장합니다.
그래서 Windows에서 페어링하면 기기에 저장된 키가 바뀌고, Linux가 가진 옛날 키는 쓸모가 없어집니다. 반대 방향도 마찬가지입니다.

**해결 방법:** 두 OS가 **같은 키**를 쓰게 만들면 됩니다. 이 도구가 그 일을 자동으로 해 줍니다.

### 특징

- 🔑 **Windows → Linux**: Linux에서 Windows 파티션을 **읽기 전용**으로 열고 레지스트리 파일(`SYSTEM` hive)에서 키를 직접 읽어 BlueZ(`/var/lib/bluetooth`)에 넣습니다. `chntpw` 같은 추가 패키지가 필요 없습니다.
- 🔁 **Linux → Windows**: Linux에서 다시 페어링한 기기의 키를 EFI 파티션에 내보내고, Windows 스크립트가 그 키를 레지스트리에 넣습니다.
- 🧠 **어느 쪽이 최신인지 기억합니다**: 동기화 기록을 저장해서 마지막으로 페어링한 OS의 키를 우선합니다. 새 키를 옛날 키로 덮어쓰지 않습니다.
- 🖱️ **블루투스 LE 기기(마우스, 키보드, 일부 이어폰)도 지원**합니다. 페어링할 때마다 주소가 바뀌는 기기(Logitech, Microsoft 마우스 등)는 이름으로 찾아 맞춥니다.
- ⚙️ **부팅할 때 자동으로 실행**됩니다(systemd 서비스, Windows 시작 작업). 한 번 설치하면 따로 할 일이 없습니다.
- 💾 바꾸기 전에 항상 **백업**합니다(Linux: `/var/backups/bt-dualboot-sync`, Windows: `C:\ProgramData\bt-dualboot-sync`).
- 🐍 Python 3.7 이상만 있으면 됩니다(Ubuntu에 기본 설치되어 있음). 외부 라이브러리는 필요 없습니다.

### 빠른 시작 (처음 한 번만)

**1. Linux에서 기기를 페어링합니다.** (이미 되어 있으면 건너뛰세요.)

**2. Windows로 재부팅해서 같은 기기를 페어링합니다.**
> 이제 기기는 Windows 키를 갖고 있고, Linux에서는 연결이 안 됩니다. 정상입니다.

추천: Windows에서 **빠른 시작(Fast Startup)을 끕니다.** 켜져 있으면 Windows가 완전히 꺼지지 않아서 Linux가 최신 레지스트리를 못 읽을 수 있습니다.
```powershell
# Windows PowerShell에서 (관리자 권한은 스크립트가 알아서 요청합니다)
.\windows\bt-dualboot-sync.ps1 -DisableFastStartup
```

**3. Ubuntu로 재부팅해서 실행합니다.**
```bash
git clone https://github.com/taehyeon03/bt-dualboot-sync.git
```
```bash
cd bt-dualboot-sync
```
```bash
sudo ./bt-dualboot-sync status
```
```bash
sudo ./bt-dualboot-sync sync
```
끝입니다. 이제 두 OS 모두에서 다시 페어링하지 않아도 연결됩니다. 🎉

**4. (추천) 부팅할 때 자동으로 실행되게 설치합니다.**
```bash
sudo ./bt-dualboot-sync install
```
이제 Linux가 부팅될 때마다 블루투스가 켜지기 **전에** 자동으로 동기화합니다.
나중에 Windows에서 기기를 다시 페어링해도 Linux로 부팅하기만 하면 됩니다.

### Linux에서 다시 페어링했다면? (Linux → Windows)

Linux에서 기기를 새로 페어링하면 이번에는 Windows 쪽 키가 옛날 키가 됩니다.

1. Linux에서 키를 내보냅니다. (`install` 했다면 부팅할 때 자동으로 됩니다.)
   ```bash
   sudo ./bt-dualboot-sync export
   ```
   키는 EFI 파티션의 `bt-dualboot-sync/bluez-keys.json`에 저장됩니다.
2. Windows로 부팅해서 `windows\import-keys.cmd`를 더블클릭하거나 PowerShell에서 실행합니다.
   ```powershell
   .\windows\bt-dualboot-sync.ps1
   ```
   Windows가 시작될 때마다 자동으로 가져오게 하려면:
   ```powershell
   .\windows\bt-dualboot-sync.ps1 -Install
   ```

> 기기가 Windows에서 **한 번이라도** 페어링되어 있어야 Windows로 키를 넣을 수 있습니다. 반대로 Linux로 넣으려면 Linux에서 한 번은 페어링되어 있어야 합니다.

### 명령어

| 명령 | 하는 일 |
|---|---|
| `sudo ./bt-dualboot-sync status` | 기기 목록과 키가 일치하는지 보여 줍니다. 아무것도 바꾸지 않습니다. |
| `sudo ./bt-dualboot-sync sync` | Windows 키를 Linux로 복사합니다. |
| `sudo ./bt-dualboot-sync export` | Linux 키를 Windows용 파일로 내보냅니다. |
| `sudo ./bt-dualboot-sync auto` | 동기화 기록을 보고 양방향으로 처리합니다(부팅 서비스가 사용). |
| `sudo ./bt-dualboot-sync install` / `uninstall` | 부팅 시 자동 실행 서비스를 설치하거나 지웁니다. |

옵션: `--dry-run`(바꿀 내용만 보기), `--yes`(묻지 않기), `--force`(기록 무시), `--windows /dev/nvme0n1p3`(Windows 파티션 직접 지정), `--irk-no-reverse`(아래 문제 해결 참고).

Windows 스크립트: `-DryRun`, `-List`(Windows에 저장된 기기 목록), `-Install`, `-Uninstall`, `-DisableFastStartup`.

### 문제 해결

- **"could not find a Windows installation"**: Windows 파티션이 **BitLocker/장치 암호화**로 잠겨 있을 수 있습니다(Windows 11 Home 노트북에 자주 켜져 있음). Windows 설정 → 개인 정보 및 보안 → 장치 암호화를 끄거나, Linux에서 `dislocker`로 잠금을 풀고 마운트한 다음 `--windows <마운트 경로>`로 지정하세요.
- **"registry was not cleanly saved" 경고**: Windows 빠른 시작 또는 최대 절전 모드 때문입니다. 빠른 시작을 끄고, Windows에서 Linux로 갈 때는 **다시 시작**을 쓰세요.
- **sync 후에도 연결이 안 될 때**: 기기 전원을 껐다 켜 보세요. 그래도 안 되면 `sudo ./bt-dualboot-sync status`로 상태를 확인하세요. `never paired in Linux`라면 Linux에서 한 번 페어링한 다음 Windows에서 다시 페어링하고 `sync`를 실행하세요.
- **주소가 바뀌는 LE 기기가 연결되지 않을 때**: `sudo ./bt-dualboot-sync sync --force --irk-no-reverse`를 실행해 보세요.
- **원래대로 되돌리기**: Linux는 `/var/backups/bt-dualboot-sync/<시간>`을 `/var/lib/bluetooth`에 다시 복사합니다. Windows는 `C:\ProgramData\bt-dualboot-sync\backup-*.reg`를 더블클릭합니다.

### 어떻게 동작하나요?

| 위치 | 저장 형식 |
|---|---|
| Windows | `HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys\<어댑터>` — 일반 기기는 `<기기 주소>` 값(16바이트), LE 기기는 `<기기 주소>` 하위 키(`LTK`, `EDIV`, `ERand`, `IRK`, `KeyLength`) |
| Linux (BlueZ) | `/var/lib/bluetooth/<어댑터>/<기기>/info` — `[LinkKey] Key=`, `[LongTermKey] Key= EDiv= Rand= EncSize=`, `[IdentityResolvingKey] Key=` |

Linux 쪽은 레지스트리 hive 파일 형식(`regf`)을 직접 읽는 작은 파서가 들어 있습니다. Windows 쪽 레지스트리 키는 SYSTEM 계정만 쓸 수 있어서, 스크립트는 SYSTEM 권한의 임시 예약 작업으로 실행됩니다.

### 보안 참고

링크 키는 기기와 암호화 연결을 맺는 비밀값입니다. 내보낸 파일(`bluez-keys.json`)은 EFI 파티션에 저장됩니다. Ubuntu는 이 파티션을 root만 읽을 수 있게 마운트하고, Windows에서는 관리자만 접근할 수 있습니다. 가져온 다음에는 자동으로 지워집니다. 이 파일을 다른 사람과 공유하지 마세요.

---

## English

### Why do I have to re-pair?

Pairing creates a secret **link key** shared by the PC and the device. Windows and Linux use the same Bluetooth adapter (same MAC address) but store their own keys. When you pair in one OS, the device forgets the key the other OS has.

**Fix:** make both OSes use the **same key**. This tool does that for you.

### Features

- **Windows → Linux**: mounts the Windows partition **read-only**, reads the keys straight from the registry file (`SYSTEM` hive, built-in parser, no `chntpw` needed), and writes them to BlueZ.
- **Linux → Windows**: exports keys from devices you re-paired in Linux to the EFI partition. The Windows script then imports them into the registry.
- **Knows which side is newer**: keeps a sync history, so it never overwrites a newer pairing with an older one.
- **Bluetooth LE support** (mice, keyboards, some earbuds), including devices that change their address every time they pair (it matches them by name).
- **Runs automatically at boot**: a systemd unit that runs before `bluetooth.service`, plus an optional Windows startup task.
- **Always backs up** before it changes anything.
- Needs only Python 3.7+ and its standard library.

### Quick start

1. Pair the device in **Linux**.
2. Reboot into **Windows** and pair the same device there. Recommended: disable Fast Startup with `.\windows\bt-dualboot-sync.ps1 -DisableFastStartup`.
3. Reboot into **Linux** and run:
   ```bash
   git clone https://github.com/taehyeon03/bt-dualboot-sync.git
   ```
   ```bash
   cd bt-dualboot-sync && sudo ./bt-dualboot-sync sync
   ```
4. Optional: run `sudo ./bt-dualboot-sync install` so this happens automatically at every boot.

If you later re-pair a device in **Linux**, run `sudo ./bt-dualboot-sync export` (or let the boot service do it). Then, in Windows, run `windows\import-keys.cmd`, or install the startup task with `.\windows\bt-dualboot-sync.ps1 -Install`.

A device must have been paired **at least once** in the OS that receives the keys.

### Commands

`status` · `sync` (Windows→Linux) · `export` (Linux→Windows) · `auto` (both directions, used at boot) · `install` / `uninstall`

Options: `--dry-run`, `--yes`, `--force`, `--windows PATH|/dev/X`, `--export-path FILE`, `--irk-no-reverse`, `-v`.

### Troubleshooting

- **BitLocker / Device Encryption** stops Linux from reading the Windows partition. Turn it off, or unlock the partition with `dislocker` and pass the mount point with `--windows`.
- **"registry was not cleanly saved"**: caused by Fast Startup or hibernation. Disable Fast Startup and use *Restart*, not *Shut down*.
- **An LE device with a private address won't reconnect**: try `sync --force --irk-no-reverse`.
- **Restore**: copy `/var/backups/bt-dualboot-sync/<time>` back to `/var/lib/bluetooth`. In Windows, double-click `C:\ProgramData\bt-dualboot-sync\backup-*.reg`.

### Development

```bash
python3 -m unittest discover -s tests -v
```
The tests build a synthetic Windows `SYSTEM` hive and a fake BlueZ tree. CI runs them on Ubuntu with several Python versions.

### License

MIT
