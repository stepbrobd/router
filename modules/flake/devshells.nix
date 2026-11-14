{
  perSystem = { lib, pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [ deno git nixpkgs-fmt taplo typstyle ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.bird3 ];
    };
  };
}
