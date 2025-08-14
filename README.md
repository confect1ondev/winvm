# winvm

A working Windows VM with Secure Boot and Guest Tools :)

## Usage
```bash
nix run github:confect1ondev/winvm#winvm --no-write-lock-file -- <vm-name> /path/to/Win11.iso
# examples:
# nix run github:confect1ondev/winvm#winvm --no-write-lock-file -- work ~/Downloads/Win11_24H2_English_x64.iso

