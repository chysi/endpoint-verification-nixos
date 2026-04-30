{
  description = "Google Endpoint Verification for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };

      mkEndpointVerification = { osName ? "NixOS" }: pkgs.stdenv.mkDerivation {
        pname = "endpoint-verification";
        version = "1765828494702-842239260";

        src = pkgs.fetchurl {
          url = "https://packages.cloud.google.com/apt/pool/endpoint-verification/endpoint-verification_1765828494702-842239260_amd64_3bcef7ad4e9e6bf8b16dae869190fca7.deb";
          sha256 = "sha256-LqglFD/VahDWrjo/JxnNR4M0effdP6pu7X9izi0KxmQ=";
        };

        deviceStateScript = pkgs.writeScript "device_state.sh" ''
          #!/bin/sh

          set -u

          INSTALL_PREFIX=/opt/google/endpoint-verification
          GENERATED_ATTRS_FILE="$INSTALL_PREFIX/var/lib/device_attrs"

          ACTION=''${1:-default}
          OS_VERSION=UNKNOWN

          log_error() {
            echo "$1" 1>&2
          }

          get_serial_number() {
            SERIAL_NUMBER_FILE=/sys/class/dmi/id/product_serial
            if [ -r "$SERIAL_NUMBER_FILE" ]; then
              SERIAL_NUMBER=$(cut -c -128 "$SERIAL_NUMBER_FILE" | tr -d '"')
            fi
          }

          get_disk_encrypted() {
            DISK_ENCRYPTED=DISABLED

            for MOUNT_TARGET in / /nix/store; do
              ROOT_SRC=$(findmnt -n -o SOURCE "$MOUNT_TARGET" 2>/dev/null) || continue
              # Strip btrfs subvolume notation, e.g. /dev/mapper/cryptroot[/root]
              ROOT_DEV=$(echo "$ROOT_SRC" | sed 's/\[.*\]//')

              FSTYPE=$(findmnt -n -o FSTYPE "$MOUNT_TARGET" 2>/dev/null)
              case "$FSTYPE" in
                tmpfs|ramfs|devtmpfs) continue ;;
              esac

              if lsblk -n -o TYPE "$ROOT_DEV" -s 2>/dev/null | grep -q '^crypt$'; then
                DISK_ENCRYPTED=ENABLED
                return
              fi
            done
          }

          get_os_name_and_version() {
            OS_INFO_FILE=/etc/os-release
            if [ -r "$OS_INFO_FILE" ]; then
              VERSION_ID=$(grep -i '^VERSION_ID=' "$OS_INFO_FILE" | awk -F= '{ print $2 }' | tr -d '"')
              OS_VERSION="${osName} ''${VERSION_ID:-UNKNOWN}"
            else
              log_error "$OS_INFO_FILE is not available."
            fi
          }

          get_screenlock_value() {
            SESSION_SPEC=$(echo "''${XDG_CURRENT_DESKTOP:-unset}""''${DESKTOP_SESSION:-unset}" | tr [:upper:] [:lower:])
            case "$SESSION_SPEC" in
              *cinnamon*) DESKTOP_ENV=cinnamon ;;
              *gnome*) DESKTOP_ENV=gnome ;;
              *unity*) DESKTOP_ENV=gnome ;;
              *)
                SCREENLOCK_ENABLED=UNKNOWN
                return
                ;;
            esac

            if [ -x "$(which gsettings)" ]; then
              LOCK_ENABLED=$(gsettings get org."$DESKTOP_ENV".desktop.screensaver lock-enabled)
            elif [ -x "$(which dconf)" ]; then
              LOCK_ENABLED=$(dconf read /org/"$DESKTOP_ENV"/desktop/screensaver/lock-enabled)
              if [ "$LOCK_ENABLED" = "" ]; then
                LOCK_ENABLED=true
              fi
            fi

            case "$LOCK_ENABLED" in
              "true") SCREENLOCK_ENABLED=ENABLED ;;
              "false") SCREENLOCK_ENABLED=DISABLED ;;
              *) SCREENLOCK_ENABLED=UNKNOWN ;;
            esac
          }

          get_hostname() {
            HOSTNAME="$(hostname)"
          }

          get_model() {
            MODEL_FILE=/sys/class/dmi/id/product_name
            if [ -r "$MODEL_FILE" ]; then
              MODEL="$(cat "$MODEL_FILE")"
            else
             log_error "$MODEL_FILE is not available."
            fi
          }

          get_all_mac_addresses() {
            SYS_CLASS_NET=/sys/class/net
            if [ -d "$SYS_CLASS_NET" ]; then
              MAC_ADDRESSES=$(cat "$SYS_CLASS_NET"/*/address | grep -v 00:00:00:00:00:00)
            else
              log_error "$SYS_CLASS_NET is not available."
            fi
          }

          get_os_firewall() {
            UWF_CONFIG_FILE=/etc/ufw/ufw.conf
            if [ -r "$UWF_CONFIG_FILE" ]; then
              OS_FIREWALL=$(grep -i '^ENABLED=' "$UWF_CONFIG_FILE" | awk -F= '{ print $2 }' | tr [:upper:] [:lower:])
            elif nft list ruleset 2>/dev/null | grep -q 'chain'; then
              OS_FIREWALL=yes
            elif iptables -L -n 2>/dev/null | grep -qv '^Chain .* (policy ACCEPT)$\|^target\|^$'; then
              OS_FIREWALL=yes
            else
              OS_FIREWALL=UNKNOWN
            fi
          }

          case "$ACTION" in
            "init")
              get_serial_number
              get_disk_encrypted

              printf "serial_number: \"%s\"\n" "$SERIAL_NUMBER"
              printf "disk_encrypted: %s\n" "$DISK_ENCRYPTED"

              exit 0
            ;;
          esac

          # Default action

          if [ -r "$GENERATED_ATTRS_FILE" ]; then
            cat "$GENERATED_ATTRS_FILE"
          fi

          get_os_name_and_version
          get_screenlock_value
          get_hostname
          get_model
          get_all_mac_addresses
          get_os_firewall

          printf "os_version: \"%s\"\n" "$OS_VERSION"
          printf "screen_lock_secured: %s\n" "$SCREENLOCK_ENABLED"
          printf "hostname: \"%s\"\n" "$HOSTNAME"
          printf "model: \"%s\"\n" "$MODEL"
          printf "os_firewall: \"%s\"\n" "$OS_FIREWALL"

          echo "$MAC_ADDRESSES" | while IFS= read -r item
          do
            printf "mac_addresses: \"%s\"\n" "$item"
          done
        '';

        nativeBuildInputs = with pkgs; [
          dpkg
          autoPatchelfHook
          jq
          gnused
          makeWrapper
        ];

        buildInputs = with pkgs; [
          gawk
          dconf
          gnugrep
          util-linux
          systemd
          coreutils
        ];

        runtimeDependencies = with pkgs; [
          coreutils
        ];

        unpackPhase = ''
          ar x $src
          tar xf data.tar.gz
        '';

        installPhase = ''
          mkdir -p $out/opt/google/endpoint-verification/bin
          mkdir -p $out/etc/init.d
          mkdir -p $out/etc/opt/chrome/native-messaging-hosts
          mkdir -p $out/usr/lib/mozilla/native-messaging-hosts

          install -m 0755 opt/google/endpoint-verification/bin/* $out/opt/google/endpoint-verification/bin/

          install -m 0755 $deviceStateScript $out/opt/google/endpoint-verification/bin/device_state.sh
          wrapProgram $out/opt/google/endpoint-verification/bin/device_state.sh \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.dconf pkgs.gnugrep pkgs.util-linux pkgs.systemd ]}

          install -m 0755 etc/init.d/endpoint-verification $out/etc/init.d/

          jq --arg path "$out/opt/google/endpoint-verification/bin/apihelper" \
            '.path = $path' \
            etc/opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json \
            > $out/etc/opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json

          if [ -f etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json ]; then
            jq --arg path "$out/opt/google/endpoint-verification/bin/SecureConnectHelper" \
              '.path = $path' \
              etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json \
              > $out/etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json
          fi

          jq --arg path "$out/opt/google/endpoint-verification/bin/apihelper" \
            '.path = $path' \
            usr/lib/mozilla/native-messaging-hosts/com.google.endpoint_verification.api_helper.json \
            > $out/usr/lib/mozilla/native-messaging-hosts/com.google.endpoint_verification.api_helper.json
        '';

        postInstall = ''
        '';

        meta = with pkgs.lib; {
          description = "Google Endpoint Verification Native Helper";
          homepage = "https://cloud.google.com/endpoint-verification";
          license = licenses.unfree;
          platforms = [ "x86_64-linux" ];
          maintainers = [ ];
        };
      };
    in
    {
      packages.${system} = {
        endpoint-verification = mkEndpointVerification {};
        default = mkEndpointVerification {};
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          dpkg
          jq
          curl
          binutils
          gnutar
          gzip
        ];
      };

      nixosModules.default = { config, pkgs, lib, ... }:
            with lib;
            let
              cfg = config.services.endpoint-verification;
              pkg = mkEndpointVerification { osName = cfg.osName; };
              firewallEnabled = config.networking.firewall.enable or false;
            in
            {
              options.services.endpoint-verification = {
                enable = mkEnableOption "Google Endpoint Verification service";
                osName = mkOption {
                  type = types.str;
                  default = "NixOS";
                  description = "OS name to prepend to the version reported by endpoint verification (e.g. \"NixOS/Trilby\").";
                };
              };

              config = mkIf cfg.enable {
                # Chrome checks /etc/ufw/ufw.conf for firewall status but NixOS
                # uses nftables/iptables. Provide a compat shim so Chrome reports
                # the actual NixOS firewall state.
                environment.etc."ufw/ufw.conf" = mkIf firewallEnabled {
                  text = "ENABLED=yes\n";
                };
                environment.systemPackages = [ pkg ];

                environment.etc."opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json".source =
                  "${pkg}/etc/opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json";

                environment.etc."chromium/native-messaging-hosts/com.google.endpoint_verification.api_helper.json".source =
                  "${pkg}/etc/opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json";

                environment.etc."opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json".source =
                  "${pkg}/etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json";

                environment.etc."chromium/native-messaging-hosts/com.google.secure_connect.native_helper.json".source =
                  "${pkg}/etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json";

                environment.etc."mozilla/native-messaging-hosts/com.google.endpoint_verification.api_helper.json".source =
                  "${pkg}/usr/lib/mozilla/native-messaging-hosts/com.google.endpoint_verification.api_helper.json";

                systemd.tmpfiles.rules = [
                  "d /opt/google/endpoint-verification/var/lib 0755 root root -"
                  "d /opt/google/endpoint-verification/bin 0755 root root -"
                  "L+ /opt/google/endpoint-verification/bin/device_state.sh - - - - ${pkg}/opt/google/endpoint-verification/bin/device_state.sh"
                ];

                systemd.services.endpoint-verification = {
                  description = "Google Endpoint Verification Service";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "systemd-tmpfiles-setup.service" ];
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = pkgs.writeShellScript "endpoint-verification-init" ''
                      ${pkg}/opt/google/endpoint-verification/bin/device_state.sh init > /opt/google/endpoint-verification/var/lib/device_attrs
                    '';
                    RemainAfterExit = true;
                  };
                };
              };
            };
    };
}
