# SSH profile - enables SSH daemon with host keys on /var
# Creates two users based on core.adminUser and core.regularUser options
{ config, lib, pkgs, ... }:

let
  adminUser = config.core.adminUser;
  regularUser = config.core.regularUser;
in
{
  config = {
    # Enable SSH daemon
    services.openssh = {
      enable = true;
      openFirewall = false;  # Firewall managed by /var/identity/tcp_ports
      authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    # SSH host key stored on /var/identity (persistent across reboots)
    services.openssh.hostKeys = [
      {
        path = "/var/identity/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    # Admin user with sudo access
    users.users.${adminUser} = {
      isNormalUser = true;
      description = "Admin User";
      extraGroups = [ "wheel" ];
    };

    # Regular user without sudo
    users.users.${regularUser} = {
      isNormalUser = true;
      description = "Regular User";
      extraGroups = [ ];
    };

    # Create home directories on /var/home (since /home is a bind mount)
    # Uses 'users' group since isNormalUser doesn't create per-user groups
    systemd.tmpfiles.rules = [
      "d /var/home/${adminUser} 0700 ${adminUser} users -"
      "d /var/home/${regularUser} 0700 ${regularUser} users -"
    ];

    # Enable passwordless sudo for wheel group
    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };

    # Create placeholders for authorized_keys bind mounts
    environment.etc."ssh/authorized_keys.d/${adminUser}" = {
      text = "";
      mode = "0600";
    };

    environment.etc."ssh/authorized_keys.d/${regularUser}" = {
      text = "";
      mode = "0600";
    };

    # Bind mount authorized_keys from /var/identity for admin
    fileSystems."/etc/ssh/authorized_keys.d/${adminUser}" = {
      device = "/var/identity/${adminUser}_authorized_keys";
      options = [ "bind" ];
      depends = [ "/var" ];
    };

    # Bind mount authorized_keys from /var/identity for regular user
    fileSystems."/etc/ssh/authorized_keys.d/${regularUser}" = {
      device = "/var/identity/${regularUser}_authorized_keys";
      options = [ "bind" ];
      depends = [ "/var" ];
    };
  };
}
