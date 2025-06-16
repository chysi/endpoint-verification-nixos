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
    in
    {
      packages.${system} = {
        endpoint-verification = pkgs.stdenv.mkDerivation {
            pname = "endpoint-verification";
            version = "2023.12.18.c591921611-00";

            src = pkgs.fetchurl {
              url = "https://packages.cloud.google.com/apt/pool/endpoint-verification/endpoint-verification_2023.12.18.c591921611-00_amd64_0ed3d7aced2a9858c943a958c4c8ee9a.deb";
              sha256 = "sha256-VX4M41J+K8OimQbLyK37rl5Gn62c+N0sp10Eqd3D3MU=";
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
                # Major number of the root device in hexadecimal
                ROOT_MAJ_HEX=$(stat / --format="%D" | awk '{print substr($1, 1, length($1)-2)}')
                # Major number of the root device
                ROOT_MAJ=$(printf "%d" 0x"$ROOT_MAJ_HEX")
                if [ "$ROOT_MAJ" = "" ]; then
                  # Root device taken from boot command line (/proc/cmdline)
                  # Ubuntu: BOOT_IMAGE=/vmlinuz-5.0.0-31-generic root=/dev/mapper/ubuntu--vg-root ro quiet splash
                  # Ubuntu: BOOT_IMAGE=/vmlinuz-5.0.0-31-generic root=UUID=2d1f8b16-ea0f-11e9-81b4-2a2ae2dbcce4 ro quiet splash
                  # Random: console=ttyO0,115200n8 noinitrd mem=256M root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait=1 ip=none
                  ROOT_DEV=$(awk -v RS=" " '/^root=/ { print substr($0,6) }' /proc/cmdline)
                  # udevadmin requires /dev/ file, but cmdline might refer to something else
                  # or the line itself might have unexpected format.
                  case "$ROOT_DEV" in
                    "/dev/*") ;;
                    *) ROOT_DEV=$(awk '$2 == "/" { print $1 }' /proc/mounts) ;;
                  esac
                  ROOT_MAJ=$(udevadm info --query=property "$ROOT_DEV" | grep MAJOR= | cut -f2 -d=)
                fi

                # Bail out if not a number
                case "$ROOT_MAJ" in
                  ""|*[!0-9]*)
                    DISK_ENCRYPTED=UNKNOWN
                    return
                    ;;
                esac

                # Parent of the root device shares the same major number and minor is zero.
                ROOT_PARENT_DEV_TYPE=$(lsblk -ln -o MAJ:MIN,TYPE | awk '$1 == "'"$ROOT_MAJ":0'" { print $2 }')
                case "$ROOT_PARENT_DEV_TYPE" in
                  "") DISK_ENCRYPTED=UNKNOWN ;;
                  "crypt") DISK_ENCRYPTED=ENABLED ;;
                  *) DISK_ENCRYPTED=DISABLED ;;
                esac
              }

              get_os_name_and_version() {
                OS_INFO_FILE=/etc/os-release
                if [ -r "$OS_INFO_FILE" ]; then
                  OS_NAME=$(grep -i '^NAME=' "$OS_INFO_FILE" | awk -F= '{ print $2 }' | tr [:upper:] [:lower:])
                  case "$OS_NAME" in
                    *ubuntu*|*debian*)
                      OS_VERSION=$(grep -i '^VERSION_ID=' "$OS_INFO_FILE" | awk -F= '{ print $2 }' | tr -d '"')
                      ;;
                    *)
                      ;;
                  esac
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

                # Try more reliable gsettings first, fall back to dconf
                if [ -x "$(which gsettings)" ]; then
                  # gsettings returns the effective state of the lock-enabled
                  LOCK_ENABLED=$(gsettings get org."$DESKTOP_ENV".desktop.screensaver lock-enabled)
                elif [ -x "$(which dconf)" ]; then
                  # dconf returns the explicitly set value or nothing in case it has never changed
                  LOCK_ENABLED=$(dconf read /org/"$DESKTOP_ENV"/desktop/screensaver/lock-enabled)
                  if [ "$LOCK_ENABLED" = "" ]; then
                    # Implicit default value is true
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
                  # filter out loopback mac addr (00:00:00:00:00:00)
                  MAC_ADDRESSES=$(cat "$SYS_CLASS_NET"/*/address | grep -v 00:00:00:00:00:00)
                else
                  log_error "$SYS_CLASS_NET is not available."
                fi
              }

              get_os_firewall() {
                UWF_CONFIG_FILE=/etc/ufw/ufw.conf
                if [ -r "$UWF_CONFIG_FILE" ]; then
                  OS_FIREWALL=$(grep -i '^ENABLED=' "$UWF_CONFIG_FILE" | awk -F= '{ print $2 }' | tr [:upper:] [:lower:])
                else
                  log_error "$UWF_CONFIG_FILE is not available."
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
              # Create all necessary directories first
              mkdir -p $out/opt/google/endpoint-verification/bin
              mkdir -p $out/etc/init.d
              mkdir -p $out/etc/opt/chrome/native-messaging-hosts
              mkdir -p $out/usr/lib/mozilla/native-messaging-hosts

              # Install the binary and scripts
              install -m 0755 opt/google/endpoint-verification/bin/* $out/opt/google/endpoint-verification/bin/

              # Install our modified device_state.sh
              install -m 0755 $deviceStateScript $out/opt/google/endpoint-verification/bin/device_state.sh
              wrapProgram $out/opt/google/endpoint-verification/bin/device_state.sh \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.dconf pkgs.gnugrep pkgs.util-linux pkgs.systemd ]}

              # Install the init script
              install -m 0755 etc/init.d/endpoint-verification $out/etc/init.d/

              # Create the native messaging host configs with the correct Nix store path
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
          default = self.packages.${system}.endpoint-verification;
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
            in
            {
              options.services.endpoint-verification = {
                enable = mkEnableOption "Google Endpoint Verification service";
              };

              config = mkIf cfg.enable {
                environment.systemPackages = [ self.packages.${system}.endpoint-verification ];

                # The native messaging host configs must be in these exact locations
                environment.etc."opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json".source = 
                  "${self.packages.${system}.endpoint-verification}/etc/opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json";
                
                environment.etc."chromium/native-messaging-hosts/com.google.endpoint_verification.api_helper.json".source = 
                  "${self.packages.${system}.endpoint-verification}/etc/opt/chrome/native-messaging-hosts/com.google.endpoint_verification.api_helper.json";

                environment.etc."opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json".source = 
                  "${self.packages.${system}.endpoint-verification}/etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json";

                environment.etc."chromium/native-messaging-hosts/com.google.secure_connect.native_helper.json".source = 
                  "${self.packages.${system}.endpoint-verification}/etc/opt/chrome/native-messaging-hosts/com.google.secure_connect.native_helper.json";
                
                environment.etc."mozilla/native-messaging-hosts/com.google.endpoint_verification.api_helper.json".source = 
                  "${self.packages.${system}.endpoint-verification}/usr/lib/mozilla/native-messaging-hosts/com.google.endpoint_verification.api_helper.json";

                # Create the directory for device attributes
                systemd.tmpfiles.rules = [
                  "d /opt/google/endpoint-verification/var/lib 0755 root root -"
                ];


                systemd.services.endpoint-verification = {
                  description = "Google Endpoint Verification Service";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "systemd-tmpfiles-setup.service" ];
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = pkgs.writeShellScript "endpoint-verification-init" ''
                      # Run the init to get serial number and disk encryption status
                      ${self.packages.${system}.endpoint-verification}/opt/google/endpoint-verification/bin/device_state.sh init > /opt/google/endpoint-verification/var/lib/device_attrs
                    '';
                    RemainAfterExit = true;
                  };
                };
              };
            };
    };
} 