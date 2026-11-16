{
  perSystem = { lib, pkgs, ... }: {
    formatter = pkgs.writeShellScriptBin "formatter" ''
      pushd "$(${lib.getExe pkgs.git} rev-parse --show-toplevel)" > /dev/null
      set -eoux pipefail
      shopt -s globstar
      export PATH=${lib.makeBinPath [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt ]}:$PATH

      ${lib.getExe pkgs.actionlint} -color
      ${lib.getExe pkgs.cargo} fmt --all
      ${lib.getExe pkgs.cargo} clippy --all-targets --all-features -- -D warnings
      ${lib.getExe pkgs.deno} fmt --prose-wrap=always --ignore=target,generated .
      ${lib.getExe pkgs.gitleaks} git --no-banner --pre-commit --staged
      ${lib.getExe pkgs.nixpkgs-fmt} .
      ${lib.getExe pkgs.taplo} format **/*.toml
      ${lib.getExe pkgs.typstyle} --inplace .
      ${lib.getExe pkgs.zizmor} --fix=all .

      popd
    '';
  };
}
