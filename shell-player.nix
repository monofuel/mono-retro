{ pkgs ? import <nixpkgs> { } }:
let
  runtime = with pkgs; [
    systemd
    libevdev
    openal
    openssl
    xorg.libX11
    xorg.libXcursor
  ];
in
pkgs.mkShell {
  packages = [ pkgs.gnumake pkgs.xorg.xorgserver ];
  buildInputs = runtime;
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtime;
  SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
}
