{ lib
, cfg
, writeTextFile
}:

writeTextFile {
  name = "bird.conf";

  derivationArgs.nativeBuildInputs = lib.optional cfg.checkConfig cfg.package;

  checkPhase = lib.optionalString cfg.checkConfig ''
    ln -s $out bird.conf
    ${cfg.preCheckConfig}
    bird -d -p -c bird.conf
  '';

  text = ''

  '';
}
