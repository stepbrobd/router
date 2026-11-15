{
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [ deno git nixpkgs-fmt taplo typst typstyle ];
    };
  };
}
