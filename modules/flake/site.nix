{ inputs, ... }:
{
  perSystem = { config, inputs', pkgs, ... }:
    let
      # one entry per setting, described from the manual of the pinned BIRD source
      options = pkgs.runCommand "bird-options.json" { nativeBuildInputs = [ config.packages.router ]; } ''
        router options ${inputs.bird} \
          --source-url https://github.com/cz-nic/bird/blob/${inputs.bird.rev}/ > "$out"
      '';
      search = inputs'.search.packages.mkSearch {
        optionsJSON = options;
        urlPrefix = "https://github.com/stepbrobd/router/blob/master/";
        baseHref = "/router/bird/";
        title = "BIRD settings";
      };
      slides = pkgs.stdenvNoCC.mkDerivation {
        name = "slides.pdf";
        src = ../../docs;
        nativeBuildInputs = [ (pkgs.typst.withPackages (ps: with ps; [ muchpdf polylux ])) ];
        buildPhase = "typst compile main.typ main.pdf";
        installPhase = "mv main.pdf $out";
      };
      index = pkgs.writeText "index.html" ''
        <!doctype html>
        <meta http-equiv="refresh" content="0; url=bird/">
        <a href="bird/">BIRD settings</a>
      '';
    in
    {
      # the GitHub Pages site, served under /router/
      packages.site = pkgs.linkFarm "site" [
        { name = "bird"; path = search; }
        { name = "slides.pdf"; path = slides; }
        { name = "index.html"; path = index; }
      ];
    };
}
