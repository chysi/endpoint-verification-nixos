# Google Endpoint Verification for NixOS

A NixOS module for Google Endpoint Verification that enables Chrome to read device serial numbers for enterprise management.

## Usage

Add to your flake inputs:

```nix
inputs.endpoint-verification.url = "github:zuplo/endpoint-verification-nixos";
```

Enable in your NixOS configuration:

```nix
{
  imports = [ endpoint-verification.nixosModules.default ];
  services.endpoint-verification.enable = true;
}
```

## Requirements

- NixOS on x86_64-linux
- Udev rule to make DMI serial number readable (see your system configuration)

## What it does

- Installs Google Endpoint Verification package
- Sets up native messaging hosts for Chrome/Chromium and Firefox  
- Creates systemd service to cache device serial number
- Enables endpoint verification for Chrome enterprise enrollment
