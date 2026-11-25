{ lib, self }:
let
  inherit (builtins) readFile match fromTOML toJSON genericClosure groupBy lessThan;
  inherit (lib)
    foldl' concatStringsSep listToAttrs filter elemAt length optional sort elem flatten unique any
    hasPrefix substring concatMap genAttrs nameValuePair
    attrValues mapAttrs attrNames assertMsg;
  inherit (self.semver) parseSemverReq;
  inherit (self.pkg-info) mkPkgInfoFromCargoToml toPkgId sanitizeDep;
in rec {

  # Resolve the dependencies graph based on the lock file.
  # Output:
  # {
  #   "libz-sys 0.1.0 (https://...)" = {
  #     # name, sha256, ... All fields from pkg info.
  #     dependencies = [
  #       {
  #         # name, kind, ... All fields from dependency in the pkg info.
  #         resolved = "libc 0.1.0 (https://...)";
  #       };
  #     };
  #   };
  # }
  #
  # We support V3 and V4. V4 only differs in percent-encoding of git query parameters.
  # See:
  # https://github.com/rust-lang/cargo/blob/rust-1.63.0/src/cargo/core/resolver/resolve.rs#L56
  # https://github.com/rust-lang/cargo/blob/rust-1.63.0/src/cargo/core/resolver/encode.rs
  resolveDepsFromLock = getPkgInfo: lock: let
    # For git sources, they are referenced without the locked hash part after `#`.
    # Define: "git+https://github.com/dtolnay/semver?tag=1.0.4#ea9ea80c023ba3913b9ab0af1d983f137b4110a5"
    # Reference: "semver 1.0.4 (git+https://github.com/dtolnay/semver?tag=1.0.4)"
    removeUrlHash = s:
      let m = match "([^#]*)#.*" s; in
      if m == null then s else elemAt m 0;

    pkgs = map
      (pkg: if pkg ? source then pkg // { source = removeUrlHash pkg.source; } else pkg)
      lock.package;

    pkgsByName = foldl' (set: { name, ... }@pkg:
      set // { ${name} = (set.${name} or []) ++ [ pkg ]; }
    ) {} pkgs;

    resolved = listToAttrs (map resolvePkg pkgs);

    resolvePkg = { name, version, source ? "", dependencies ? [], ... }@args: let
      info = getPkgInfo args;
      candidates = map findPkgId dependencies;

      id = toPkgId args;
      resolvedDependencies =
        map (dep: dep // {
          resolved = selectDep candidates dep;
        }) info.dependencies;

      # Find the exact package id of a dependency key, which may omit version or source.
      findPkgId = key: let
        m = match "([^ ]+)( ([^ ]+))?( \\(([^\\)]*)\\))?" key;
        lockName = elemAt m 0;
        lockVersion = elemAt m 2;
        lockSource = elemAt m 4;
        candidates =
          filter (pkg:
            (lockVersion != null -> pkg.version == lockVersion) &&
            (lockSource != null -> pkg.source or null == lockSource))
          (pkgsByName.${lockName} or []);
        candidateCnt = length candidates;
      in
        if candidateCnt == 0 then
          throw "When resolving ${id}, locked dependency `${key}` not found"
        else if candidateCnt > 1 then
          throw ''
            When resolving ${id}, locked dependency `${key}` is ambiguous.
            Found: ${toJSON candidates}
          ''
        else
          elemAt candidates 0;

      selectDep = candidates: { name, package, req, source ? null, ... }:
        let
          # Local path or git dependencies don't have version req.
          checkReq = if req != null then parseSemverReq req else (ver: true);
          checkSource = if source != null then s: s == source else s: true;

          selected = filter
            ({ name, version, source ? null, ... }: name == package && checkReq version && checkSource source)
            candidates;

          selectedCnt = length selected;
        in
          if selectedCnt == 0 then
            # Cargo will omit disabled optional dependencies in lock file.
            # throw "When resolving ${pkgName} ${crateVersion}, dependency ${package} ${req} isn't satisfied in lock file"
            null
          else if selectedCnt > 1 then
            throw ''
              When resolving ${id}, dependency ${package} ${if req == null then "*" else req} has multiple candidates in lock file.
              Found: ${toJSON selected}
            ''
          else
            toPkgId (elemAt selected 0);

    in
      {
        name = toPkgId args;
        value = info // { dependencies = resolvedDependencies; };
      };

  in
    assert assertMsg (elem (lock.version or 3) [ 3 4 ]) "Unsupported version of Cargo.lock: ${toString lock.version}";
    resolved;

  # Resolve features of all packages reachable from `rootId`, following Cargo semantics of
  # `dep:d`, `d/f`, `d?/f` and implicit features of optional dependencies.
  #
  # Returns, for reachable packages only:
  # {
  #   "libc 0.1.0 (https://...)" = { features = [ "default" "std" ]; deps = [ "serde" ]; };
  # }
  # where `deps` are names of enabled optional dependencies.
  resolveFeatures = {
  # Follows the layout of the output of `resolveDepsFromLock`.
    pkgSet
  # Dependency edges (`{ name, kind, resolved, ... }`) will be checked by this filter.
  # Only edges returning `true` are considered and propagated.
  , depFilter ? dep: true
  # Eg. "libc 0.1.0 (https://...)"
  , rootId
  # Eg. [ "foo" "bar/baz" ]
  , rootFeatures
  }: let

    # Implicit features are collected from all optional dependencies, even filtered out ones.
    # This happens on `rand@0.8.3`, whose `default` feature enables `rand_hc`, which is only available
    # for `cfg(target_os = "emscripten")`.
    featureDefs = mapAttrs (id: { features, dependencies, ... }: let
      allRefs = flatten (attrValues features);
      implicit = filter
        (name: !elem "dep:${name}" allRefs && !(features ? ${name}))
        (unique (map (dep: dep.name) (filter (dep: dep.optional) dependencies)));
    in
      genAttrs implicit (name: [ "dep:${name}" ]) // features
    ) pkgSet;

    depsOf = mapAttrs (id: info: filter depFilter info.dependencies) pkgSet;
    namedDeps = id: name: filter (dep: dep.name == name) depsOf.${id};
    hasOptional = id: name: any (dep: dep.name == name && dep.optional) pkgSet.${id}.dependencies;

    resolvedOf = id: dep:
      if dep.resolved == null then
        throw "When resolving ${id}, dependency `${dep.name}` is enabled but missing in Cargo.lock"
      else
        dep.resolved;

    mkFact = kind: id: x: y: { key = concatStringsSep "\n" [ kind id x y ]; inherit kind id x y; };
    active = id: mkFact "active" id "" "";
    feat = id: f: mkFact "feat" id f "";
    optDep = id: name: mkFact "dep" id name "";

    activate = id: dep: let r = resolvedOf id dep; in
      [ (active r) ]
      ++ optional (dep.default_features && featureDefs.${r} ? default) (feat r "default")
      ++ map (feat r) dep.features;

    # Facts implied by an entry of a feature definition.
    expand = id: v: let
      m = match "([^/?]+)(\\?)?/(.+)" v;
      name = elemAt m 0;
    in
      if hasPrefix "dep:" v then
        [ (optDep id (substring 4 (-1) v)) ]
      else if m == null then
        [ (feat id v) ]
      else
        [ (mkFact (if elemAt m 1 != null then "weak" else "strong") id name (elemAt m 2)) ];

    # `enabledDeps` is the set of optional dependencies enabled in the previous round,
    # needed by weak features which are not monotonic within a single closure.
    step = enabledDeps: { kind, id, x, y, ... }:
      if kind == "active" then
        concatMap (activate id) (filter (dep: !dep.optional) depsOf.${id})
      else if kind == "feat" then
        [ (active id) ]
        ++ concatMap (expand id) (featureDefs.${id}.${x} or (throw ''
          Feature '${x}' is invalid for ${id}.
          Possible features: ${concatStringsSep "," (attrNames featureDefs.${id})}
        ''))
      else if kind == "dep" then
        concatMap (activate id) (filter (dep: dep.optional) (namedDeps id x))
      else if kind == "strong" then
        # `d/f` also enables the implicit feature `d`, if any.
        optional (hasOptional id x) (if featureDefs.${id} ? ${x} then feat id x else optDep id x)
        ++ map (dep: feat (resolvedOf id dep) y) (namedDeps id x)
      else
        map (dep: feat (resolvedOf id dep) y)
          (filter (dep: !dep.optional || enabledDeps ? ${"${id}\n${x}"}) (namedDeps id x));

    roots = [ (active rootId) ] ++ concatMap (expand rootId) rootFeatures;

    fixDeps = enabledDeps: let
      facts = genericClosure { startSet = roots; operator = step enabledDeps; };
      enabledDeps' = listToAttrs
        (map (f: nameValuePair "${f.id}\n${f.x}" true)
          (filter (f: f.kind == "dep") facts));
    in
      if length (attrNames enabledDeps') == length (attrNames enabledDeps) then
        facts
      else
        fixDeps enabledDeps';

    namesOf = kind: facts: sort lessThan (map (f: f.x) (filter (f: f.kind == kind) facts));

  in
    mapAttrs (id: facts: {
      features = namesOf "feat" facts;
      deps = namesOf "dep" facts;
    }) (groupBy (f: f.id) (fixDeps { }));

  resolve-feature-tests = { assertEq, ... }: let
    test = pkgSet: rootId: rootFeatures: expect:
      assertEq (resolveFeatures { inherit pkgSet rootId rootFeatures; }) expect;

    mkDep = name: resolved: args: {
      inherit name resolved;
      optional = false;
      default_features = true;
      features = [];
    } // args;

    pkgSet1 = {
      a = {
        features = { foo = [ "bar" ]; bar = []; baz = [ "b" ]; };
        dependencies = [
          (mkDep "b" "b-id" { optional = true; features = [ "a" ]; })
          (mkDep "unused" null { optional = true; })
        ];
      };
      b-id = {
        features = { default = []; foo = []; bar = [ "foo" ]; a = []; };
        dependencies = [];
      };
    };

    pkgSet2 = {
      my-id = {
        features = { default = [ "tokio/macros" ]; };
        dependencies = [
          (mkDep "tokio" "tokio-id" { default_features = false; features = [ "fs" ]; })
          (mkDep "dep" "dep-id" { })
        ];
      };
      dep-id = {
        features = { default = [ "tokio/sync" ]; };
        dependencies = [
          (mkDep "tokio" "tokio-id" { default_features = false; features = [ "sync" ]; })
        ];
      };
      tokio-id = {
        features = { default = []; fs = []; sync = []; macros = []; io = []; };
        dependencies = [];
      };
    };

    # `serde` is namespaced, `log` is weak.
    pkgSet3 = {
      a = {
        features = { json = [ "dep:serde" "log?/std" ]; logging = [ "dep:log" ]; };
        dependencies = [
          (mkDep "serde" "serde-id" { optional = true; })
          (mkDep "log" "log-id" { optional = true; default_features = false; })
        ];
      };
      serde-id = { features = {}; dependencies = []; };
      log-id = { features = { std = []; }; dependencies = []; };
    };

    noDeps = features: { inherit features; deps = []; };

  in {
    simple = test pkgSet1 "a" [ "foo" ] {
      a = noDeps [ "bar" "foo" ];
    };

    depend = test pkgSet1 "a" [ "foo" "baz" ] {
      a = { features = [ "b" "bar" "baz" "foo" ]; deps = [ "b" ]; };
      b-id = noDeps [ "a" "default" ];
    };

    override = test pkgSet1 "a" [ "b/bar" ] {
      a = { features = [ "b" ]; deps = [ "b" ]; };
      b-id = noDeps [ "a" "bar" "default" "foo" ];
    };

    merge = test pkgSet2 "my-id" [ "default" ] {
      my-id = noDeps [ "default" ];
      dep-id = noDeps [ "default" ];
      tokio-id = noDeps [ "fs" "macros" "sync" ];
    };

    namespaced = test pkgSet3 "a" [ "json" ] {
      a = { features = [ "json" ]; deps = [ "serde" ]; };
      serde-id = noDeps [ ];
    };

    weak-enabled = test pkgSet3 "a" [ "json" "logging" ] {
      a = { features = [ "json" "logging" ]; deps = [ "log" "serde" ]; };
      serde-id = noDeps [ ];
      log-id = noDeps [ "std" ];
    };

    weak-root = test pkgSet3 "a" [ "log?/std" ] {
      a = noDeps [ ];
    };
  };

  resolve-deps-tests = { assertEq, defaultRegistries, ... }: {
    simple = let
      index = {
        libc."0.1.12" = { name = "libc"; version = "0.1.12"; dependencies = []; };
        libc."0.2.95" = { name = "libc"; version = "0.2.95"; dependencies = []; };
        testt."0.1.0" = {
          name = "testt";
          version = "0.1.0";
          dependencies = map sanitizeDep [
            { name = "libc"; req = "^0.1.0"; kind = "normal"; }
            { name = "liba"; package = "libc"; req = "^0.2.0"; kind = "normal"; }
          ];
        };
      };

      lock = {
        package = [
          {
            name = "libc";
            version = "0.1.12";
            source = "registry+https://github.com/rust-lang/crates.io-index";
          }
          {
            name = "libc";
            version = "0.2.95";
            source = "registry+https://github.com/rust-lang/crates.io-index";
          }
          {
            name = "testt";
            version = "0.1.0";
            dependencies = [
             "libc 0.1.12"
             "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)"
            ];
          }
        ];
      };

      expected = {
        "libc 0.1.12 (registry+https://github.com/rust-lang/crates.io-index)" = {
          name = "libc";
          version = "0.1.12";
          dependencies = [ ];
        };
        "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)" = {
          name = "libc";
          version = "0.2.95";
          dependencies = [ ];
        };
        "testt" = {
          name = "testt";
          version = "0.1.0";
          dependencies = [
            {
              name = "libc";
              package = "libc";
              req = "^0.1.0";
              resolved = "libc 0.1.12 (registry+https://github.com/rust-lang/crates.io-index)";
              kind = "normal";
              optional = false;
              features = [];
              default_features = true;
              target = null;
            }
            {
              name = "liba";
              rename = "liba";
              package = "libc";
              req = "^0.2.0";
              resolved = "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)";
              kind = "normal";
              optional = false;
              features = [];
              default_features = true;
              target = null;
            }
          ];
        };
      };

      getPkgInfo = { name, version, ... }: index.${name}.${version};
      resolved = resolveDepsFromLock getPkgInfo lock;
    in
      assertEq resolved expected;

    workspace-virtual = let
      lock = fromTOML (readFile ../tests/workspace-virtual/Cargo.lock);
      cargoTomlFoo = fromTOML (readFile ../tests/workspace-virtual/crates/foo/Cargo.toml);
      cargoTomlBar = fromTOML (readFile ../tests/workspace-virtual/crates/bar/Cargo.toml);
      infoFoo = mkPkgInfoFromCargoToml cargoTomlFoo "<src>";
      infoBar = mkPkgInfoFromCargoToml cargoTomlBar "<src>";

      getCrateInfo = args:
        if args ? source then
          throw "No crates.io dependency"
        else if args.name == "foo" then
          infoFoo
        else if args.name == "bar" then
          infoBar
        else
          throw "Unknow crate: ${toJSON args}";

      resolved = resolveDepsFromLock getCrateInfo lock;
    in
    assertEq resolved {
      bar = {
        dependencies = [];
        features = {};
        links = null;
        name = "bar";
        procMacro = false;
        src = "<src>";
        version = "0.1.0";
      };
      foo = {
        dependencies = [ {
          default_features = true;
          features = [];
          kind = "normal";
          name = "bar";
          optional = false;
          package = "bar";
          req = null;
          resolved = "bar";
          source = null;
          target = null;
        } ];
        features = {};
        links = null;
        name = "foo";
        procMacro = false;
        src = "<src>";
        version = "0.1.0";
      };
    };
  };
}
