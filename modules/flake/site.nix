{ inputs, ... }:
{
  perSystem = { config, inputs', pkgs, ... }:
    let
      # one entry per setting under services.bird.settings, described from the manual of the pinned BIRD source
      bird = pkgs.runCommand "bird-options.json" { nativeBuildInputs = [ config.packages.router ]; } ''
        router options ${inputs.bird} --prefix services.bird.settings \
          --source-url https://github.com/cz-nic/bird/blob/${inputs.bird.rev}/ > "$out"
      '';
      # a module joins the search as another scope, from an options.json or from `modules = [ ... ]`
      # the scope picker appears once there are two
      search = inputs'.search.packages.mkMultiSearch {
        baseHref = "/router/";
        title = "NixOS Router";
        scopes = [
          {
            name = "BIRD";
            optionsJSON = bird;
            urlPrefix = "https://github.com/stepbrobd/router/blob/master/";
          }
        ];
      };
      slides = pkgs.stdenvNoCC.mkDerivation {
        name = "slides.pdf";
        src = ../../docs;
        nativeBuildInputs = [ (pkgs.typst.withPackages (ps: with ps; [ muchpdf polylux ])) ];
        buildPhase = "typst compile main.typ main.pdf";
        installPhase = "mv main.pdf $out";
      };
    in
    {
      # the GitHub Pages site, the search at /router/ with the NixCon slides beside it
      packages.site = pkgs.symlinkJoin {
        name = "site";
        paths = [ search (pkgs.linkFarm "slides" [{ name = "slides.pdf"; path = slides; }]) ];
      };
    };
}
