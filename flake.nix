{
  description = "Windows VM w/ Secure Boot and Guest Tools";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs, ... }:
  let
    systems = [ "x86_64-linux" ];
    forAll = f: builtins.listToAttrs (map (s: { name = s; value = f s; }) systems);
  in {
    apps = forAll (system:
      let
        pkgs = import nixpkgs { inherit system; };
        ovmfCode = "${pkgs.OVMFFull.fd}/FV/OVMF_CODE.ms.fd";
        ovmfVars = "${pkgs.OVMFFull.fd}/FV/OVMF_VARS.ms.fd";
        drv = pkgs.writeShellScriptBin "winvm" ''
          #!/usr/bin/env bash
          set -euo pipefail
          export PATH="${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.curl pkgs.qemu pkgs.swtpm ]}":$PATH

          usage() {
            cat <<USAGE
Usage:
  # First install (needs ISO):
  nix run .#winvm -- <vm-name> /path/to/Win11.iso [--ram 8192] [--cpus 4] [--no-tools] [--relative] [--no-tpm]

  # Subsequent boots (ISO optional; boots existing disk):
  nix run .#winvm -- <vm-name> [--ram 8192] [--cpus 4] [--no-tools] [--relative] [--no-tpm]
USAGE
          }

          # --- Positional args: <vm-name> [<windows.iso>] ---
          [ $# -ge 1 ] || { usage; exit 1; }
          VM_NAME="''${1:-}"; shift

          ISO=""
          if [ $# -gt 0 ] && [[ "''${1:-}" != --* ]]; then
            ISO="''${1:-}"; shift
          fi

          RAM=8192
          CPUS=4
          TOOLS=1               # mount VirtIO guest tools :D
          INPUT_MODE="tablet"   # otherwise its kinda jank lol
          TPM_REQUESTED=1       # default on so it works ootb

          while [ $# -gt 0 ]; do
            case "$1" in
              --ram)      RAM="$2"; shift 2;;
              --cpus)     CPUS="$2"; shift 2;;
              --no-tools) TOOLS=0;  shift 1;;
              --relative) INPUT_MODE="relative"; shift 1;;
              --no-tpm)   TPM_REQUESTED=0; shift 1;;
              *) echo "Unknown arg: $1" >&2; usage; exit 1;;
            esac
          done

          # Per-VM state
          STATE_BASE="''${XDG_DATA_HOME:-$HOME/.local/share}/winvm"
          VM_DIR="''${STATE_BASE}/''${VM_NAME}"
          mkdir -p "''${VM_DIR}"
          cd "''${VM_DIR}"

          # if its a new vm, you're gonna need the ISO...
          if [ ! -f "''${VM_NAME}.qcow2" ] && [ -z "''${ISO}" ]; then
            echo "This VM has no disk yet and no installer ISO was provided."
            echo "Run again as: nix run .#winvm -- ''${VM_NAME} /path/to/Win11.iso"
            exit 1
          fi

          if [ -n "''${ISO}" ] && [ ! -f "''${ISO}" ]; then
            echo "Installer ISO not found: ''${ISO}" >&2
            exit 1
          fi

          # ovmf (ms keys) w/ right perms
          if [ ! -f OVMF_CODE.fd ]; then install -m 0444 '${ovmfCode}' OVMF_CODE.fd; fi
          if [ ! -f OVMF_VARS.fd ]; then install -m 0600 '${ovmfVars}' OVMF_VARS.fd; else chmod 0600 OVMF_VARS.fd || true; fi

          # Disk image
          if [ ! -f "''${VM_NAME}.qcow2" ]; then qemu-img create -f qcow2 "''${VM_NAME}.qcow2" 120G >/dev/null; fi

          # download guest tools once per VM, simple and lazy lol
          VIRTIO="''${PWD}/virtio-win.iso"
          if [ "''${TOOLS}" -eq 1 ] && [ ! -f "''${VIRTIO}" ]; then
            echo "Downloading VirtIO guest tools (stable)…"
            rm -f "virtio-win.iso.part" || true
            curl -L --fail --progress-bar \
              -o "virtio-win.iso.part" \
              "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
            mv "virtio-win.iso.part" "virtio-win.iso" || true
          fi

          # Accel
          ACCEL="tcg"; [ -r /dev/kvm ] && ACCEL="kvm"

          # Display backend: GTK → SDL → VNC :5
          DISP="none"
          if qemu-system-x86_64 -display help 2>&1 | grep -q 'gtk'; then
            DISP="gtk"
          elif qemu-system-x86_64 -display help 2>&1 | grep -q 'sdl'; then
            DISP="sdl"
          else
            echo "No GTK/SDL display available; falling back to VNC :5"
          fi

          # cd first only if an iso was provided
          BOOT_ORDER="c,menu=on"
          if [ -n "''${ISO}" ]; then
            BOOT_ORDER="d,menu=on"
          fi

          # ---- TPM capability probe ----
          have_tpm_socket() {
            qemu-system-x86_64 -chardev help 2>&1 | grep -qiE '(^|[[:space:],])socket([[:space:],]|$)'
          }

          TPM_ENABLED=0
          TPM_REASON="disabled by flag"
          if [ "''${TPM_REQUESTED}" -eq 1 ]; then
            if have_tpm_socket; then
              mkdir -p .tpm
              [ -S .tpm/swtpm-sock ] && rm -f .tpm/swtpm-sock
              swtpm socket --tpm2 \
                --tpmstate dir=.tpm \
                --ctrl type=unixio,path=.tpm/swtpm-sock \
                --log level=20 >/dev/null 2>&1 &
              TPM_PID=$!
              trap 'kill $TPM_PID >/dev/null 2>&1 || true' EXIT
              TPM_ENABLED=1
              TPM_REASON="on"
            else
              TPM_REASON="off (qemu lacks chardev socket)"
            fi
          fi

          echo "State dir: ''${VM_DIR}"
          echo "VM: ''${VM_NAME}  RAM=''${RAM}  vCPUs=''${CPUS}  accel=''${ACCEL}"
          echo "ISO: $([ -n "''${ISO}" ] && echo "''${ISO}" || echo "(none)")"
          echo "TPM: ''${TPM_REASON}"
          echo "Pointer: ''${INPUT_MODE}"
          if [ "''${TOOLS}" -eq 1 ]; then
            if [ -f "''${VIRTIO}" ]; then
              echo "Guest tools ISO: ''${VIRTIO}"
            else
              echo "Guest tools: skipped (download failed)"
            fi
          fi

          # --- usb ctrl detection (for q35) ---
          DEVHELP="$(qemu-system-x86_64 -device help 2>&1 || true)"
          USB_ARGS=()
          if echo "$DEVHELP" | grep -q 'qemu-xhci'; then
            USB_ARGS+=( -device qemu-xhci )
          elif echo "$DEVHELP" | grep -q 'nec-usb-xhci'; then
            USB_ARGS+=( -device nec-usb-xhci )
          elif echo "$DEVHELP" | grep -q 'usb-ehci'; then
            USB_ARGS+=( -device usb-ehci )
          else
            USB_ARGS+=( -usb )
          fi

          # Input device (tablet works best for me, but ymmv)
          INPUT_ARGS=()
          if [ "''${INPUT_MODE}" = "tablet" ]; then
            INPUT_ARGS+=( -device usb-tablet )
          else
            INPUT_ARGS+=( -device usb-mouse )
          fi

          # Base args (q35 + virtio-vga; IDE disk so installer sees it)
          ARGS=(
            -machine q35,smm=on
            -accel "''${ACCEL}"
            -cpu host,pmu=on
            -smp "''${CPUS}" -m "''${RAM}"
            -boot "order=''${BOOT_ORDER}"

            -drive "if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd"
            -drive "if=pflash,format=raw,file=OVMF_VARS.fd"

            -drive "file=''${VM_NAME}.qcow2,if=ide,index=0,media=disk"

            -device virtio-vga
            -serial mon:stdio
          )

          # Only attach the installer CD if provided
          if [ -n "''${ISO}" ]; then
            ARGS+=( -drive "file=''${ISO},media=cdrom" )
          fi

          # Display args
          if [ "''${DISP}" = "gtk" ]; then
            ARGS+=( -display gtk )
          elif [ "''${DISP}" = "sdl" ]; then
            ARGS+=( -display sdl )
          else
            ARGS+=( -display none -vnc :5 )
            echo "Headless VNC: connect to :5"
          fi

          # usb and inputs
          ARGS+=( "''${USB_ARGS[@]}" )
          ARGS+=( "''${INPUT_ARGS[@]}" )

          # TPM args
          if [ "''${TPM_ENABLED}" -eq 1 ]; then
            ARGS+=( -chardev "socket,id=chrtpm,path=.tpm/swtpm-sock" )
            ARGS+=( -tpmdev "emulator,id=tpm0,chardev=chrtpm" )
            ARGS+=( -device  "tpm-crb,tpmdev=tpm0" )
          fi

          # guest tools!!!
          if [ "''${TOOLS}" -eq 1 ] && [ -f "''${VIRTIO}" ]; then
            ARGS+=( -drive "file=''${VIRTIO},media=cdrom" )
          fi

          exec qemu-system-x86_64 "''${ARGS[@]}"
        '';
      in {
        winvm = { type = "app"; program = "${drv}/bin/winvm"; };
      });
  };
}
