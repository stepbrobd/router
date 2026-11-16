{
  perSystem = { config, lib, pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        deno
        git
        nixpkgs-fmt
        taplo
        typstyle
        cargo
        cargo-nextest
        rustc
        clippy
        rustfmt
        rust-analyzer
        m4
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ config.packages.bird ];
    };
  };
}
