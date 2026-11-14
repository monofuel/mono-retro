{ pkgs ? import <nixpkgs> { } }:
let
  caBundle = if builtins.pathExists "/etc/ssl/certs/ca-certificates.crt"
    then "/etc/ssl/certs/ca-certificates.crt"
    else "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  runtime = with pkgs; [
    curl
    systemd
    libevdev
    alsa-lib
    openal
    openssl
    xorg.libX11
    xorg.libXcursor
    libglvnd
    mesa
  ];
in
pkgs.mkShell {
  packages = [ pkgs.gnumake pkgs.xorg.xorgserver ];
  buildInputs = runtime;
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtime;
  NIX_LDFLAGS = "-rpath ${pkgs.lib.makeLibraryPath runtime}";
  SSL_CERT_FILE = caBundle;
}
