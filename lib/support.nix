{ lib, self }:
let
  inherit (builtins) fromTOML toJSON match tryEval split pathExists genericClosure storeDir intersectAttrs length;
  inherit (lib)
    readFile mapAttrs mapAttrs' makeOverridable warnIf
    isString isAttrs hasPrefix
    filter flatten elem elemAt head splitString listToAttrs subtractLists concatStringsSep concatMap optional genAttrs sublist foldl' max
    attrNames attrValues recursiveUpdate optionalAttrs;
  inherit (self.pkg-info) mkPkgInfoFromCargoToml getPkgInfoFromIndex toPkgId;
  inherit (self.resolve) resolveDepsFromLock resolveFeatures;
  inherit (self.target-cfg) platformToCfgs evalTargetCfgStr;
  inherit (self.glob) globMatchDir;
in
rec {

  # https://doc.rust-lang.org/cargo/reference/profiles.html#default-profiles
  defaultProfiles = rec {
    dev = {
      name = "dev";
      build-override = defaultBuildProfile;
      opt-level = 0;
      debug = true;
      debug-assertions = true;
      overflow-checks = true;
      lto = false;
      panic = "unwind";
      codegen-units = 256;
      rpath = false;
    };
    release = {
      name = "release";
      build-override = defaultBuildProfile;
      opt-level = 3;
      debug = false;
      debug-assertions = false;
      overflow-checks = false;
      lto = false;
      panic = "unwind";
      codegen-units = 16;
      rpath = false;
    };
    test = dev // { name = "test"; };
    bench = release // { name = "bench"; };
  };

  defaultBuildProfile = {
    opt-level = 0;
    codegen-units = 256;
  };

  profilesFromManifest = manifest:
    let
      knownFields = [
        "name"
        "inherits"
        # "package" # Unsupported yet.
        "build-override"

        "opt-level"
        "debug"
        # split-debug-info # Unsupported.
        "strip"
        "debug-assertions"
        "overflow-checks"
        "lto"
        "panic"
        # incremental # Unsupported.
        "codegen-units"
        "rpath"
      ];

      profiles = mapAttrs (name: p:
        let unknown = removeAttrs p knownFields; in
        warnIf (unknown != {}) "Unsupported fields of profile ${name}: ${toString (attrNames unknown)}"
          (optionalAttrs (p ? inherits) profiles.${p.inherits} // p)
      ) (recursiveUpdate defaultProfiles (manifest.profile or {}));

    in profiles;

  mkRustPackageOrWorkspace =
    { defaultRegistries, pkgsBuildHost, buildRustCrate, stdenv }@default:
    { src # : Path
    , gitSrcs ? {} # : Attrset Path
    , buildCrateOverrides ? {} # : Attrset (Attrset _)
    , extraRegistries ? {} # : Attrset Registry
    , registries ? defaultRegistries // extraRegistries

    , rustc ? pkgsBuildHost.rustc
    , stdenv ? default.stdenv
    }:
    let
      manifest = readManifest src;

      profiles = profilesFromManifest manifest;

      lock = fromTOML (readFile (src + "/Cargo.lock"));
      # We don't distinguish between v1 and v2. But v3 is different from both.
      lockVersion = lock.version or 2;

      # Names of locked packages with `source` satisfying `pred`.
      lockedNames = pred: genAttrs
        (map (pkg: pkg.name) (filter (pkg: pred (pkg.source or null)) lock.package))
        (_: null);

      localSrcInfos = collectLocalCrates lockVersion (lockedNames (source: source == null))
        src
        (workspaceRoots src manifest);

    in mkRustPackageSet {
      # A git repository may contain several crates, keyed by name.
      gitSrcInfos = mapAttrs (url: src:
        mapAttrs' (id: info: { inherit (info) name; value = info; })
          (collectLocalCrates lockVersion (lockedNames (source: source != null && head (splitString "#" source) == "git+${url}"))
            src
            (workspaceRoots src (readManifest src)))
      ) gitSrcs;

      inherit lock profiles localSrcInfos buildRustCrate buildCrateOverrides registries rustc stdenv;
    };

  readManifest = root: fromTOML (readFile (root + "/Cargo.toml"));

  depTableNames = genAttrs [ "dependencies" "dev-dependencies" "build-dependencies" ] (_: null);

  # Package roots of a workspace or a single package.
  workspaceRoots = root: manifest:
    if manifest ? workspace then
      let
        selected = flatten (map (glob: globMatchDir glob root) (manifest.workspace.members or []));
        excluded = map sanitizeRelativePath (manifest.workspace.exclude or []);
        members = filter
          (path: pathExists (root + "/${path}/Cargo.toml"))
          (subtractLists excluded selected);
      in
        optional (manifest ? package) root ++ map (path: root + "/${path}") members
    else
      [ root ];

  # The closest directory containing a `[workspace]` manifest, starting from `dir` itself.
  findWorkspaceRoot = dir:
    if pathExists (dir + "/Cargo.toml") && readManifest dir ? workspace then
      dir
    else
      let parent = dirOf dir; in
      if parent == dir || toString parent == storeDir then null else findWorkspaceRoot parent;

  # Resolve `workspace = true` package fields and dependencies against the workspace at `wsRoot`,
  # and make dependency paths absolute.
  normalizeManifest = wsRoot: root: manifest: let
    ws = if wsRoot == null then {} else (readManifest wsRoot).workspace or {};
    wsDeps = mapAttrs (name: dep:
      if isString dep then
        { version = dep; }
      else
        dep // optionalAttrs (dep ? path) { path = wsRoot + "/${dep.path}"; }
    ) (ws.dependencies or {});

    isInherited = v: isAttrs v && v.workspace or false;

    fixDep = name: dep:
      if isInherited dep then
        let
          base = wsDeps.${name}
            or (throw "Dependency `${name}` of ${toString root} is not in workspace dependencies");
        in
          base // removeAttrs dep [ "workspace" "features" "default-features" ] // {
            features = base.features or [] ++ dep.features or [];
            # Members can only add default features, not remove them.
            default-features = base.default-features or true || dep.default-features or false;
          }
      else if isAttrs dep && dep ? path then
        dep // { path = root + "/${dep.path}"; }
      else
        dep;

    fixDepTables = table: table // mapAttrs (_: mapAttrs fixDep) (intersectAttrs depTableNames table);

    package = mapAttrs (field: v:
      if isInherited v then
        ws.package.${field}
          or (throw "Field `package.${field}` of ${toString root} is not in workspace")
      else
        v
    ) manifest.package;
  in
    fixDepTables manifest
    // { inherit package; }
    // optionalAttrs (manifest ? target) { target = mapAttrs (_: fixDepTables) manifest.target; };

  # Pkg infos of local crates at `roots` and all crates in `lockedNames` reachable from them via
  # path dependencies, which may be outside the workspace.
  collectLocalCrates = lockVersion: lockedNames: srcRoot: roots: let
    load = root: {
      key = toString root;
      inherit root;
      manifest = normalizeManifest (findWorkspaceRoot root) root (readManifest root);
    };

    pathDeps = manifest:
      concatMap
        (table: concatMap
          (deps: concatMap
            (name: let dep = deps.${name}; in
              optional (isAttrs dep && dep ? path && lockedNames ? ${dep.package or name}) dep.path)
            (attrNames deps))
          (attrValues (intersectAttrs depTableNames table)))
        ([ manifest ] ++ attrValues (manifest.target or {}));

    crates = genericClosure {
      startSet = map load roots;
      operator = { manifest, ... }: map load (pathDeps manifest);
    };
  in
    listToAttrs (map ({ root, manifest, ... }: let
      src = crateSrc srcRoot root manifest;
    in {
      name = toPkgId manifest.package;
      value = mkPkgInfoFromCargoToml (manifest // { inherit lockVersion; }) src.base // {
        inherit (src) crateSubdir;
        manifest = intersectAttrs (genAttrs [ "package" "lib" "bin" ] (_: null)) manifest;
      };
    }) crates);

  # Crates may read files anywhere in `srcRoot` (e.g. via `include_str!`), and target paths may
  # point outside of the crate directory. Returns the source covering both, with the crate path
  # inside it.
  crateSrc = srcRoot: root: manifest: let
    segmentsOf = path: filter (s: isString s && s != "") (split "/" (toString path));
    rootSegments = segmentsOf root;
    srcRootSegments = segmentsOf srcRoot;
    inSrcRoot = sublist 0 (length srcRootSegments) rootSegments == srcRootSegments;

    targetPaths =
      optional (manifest.lib.path or null != null) manifest.lib.path
      ++ map (bin: bin.path) (filter (bin: bin ? path) (manifest.bin or []))
      ++ optional (isString (manifest.package.build or null)) manifest.package.build;
    countUps = path: let
      segments = filter (s: s != ".") (segmentsOf path);
      go = n: if n < length segments && elemAt segments n == ".." then go (n + 1) else n;
    in
      go 0;
    ups = foldl' max 0
      (optional inSrcRoot (length rootSegments - length srcRootSegments) ++ map countUps targetPaths);

    ancestor = n: dir: if n == 0 then dir else ancestor (n - 1) (dirOf dir);
    base = ancestor ups root;
    subdir = concatStringsSep "/" (sublist (length rootSegments - ups) ups rootSegments);
  in
    if ups == 0 then
      { base = root; crateSubdir = null; }
    else if toString base == storeDir || toString base == "/" then
      throw "Target paths of ${toString root} point outside of its source"
    else
      { inherit base; crateSubdir = subdir; };

  # -> { <profile-name> = { <member-pkg-name> = <drv>; }; }
  mkRustPackageSet =
    { lock # : <fromTOML>
    , localSrcInfos # : Attrset PkgInfo
    , gitSrcInfos # : Attrset PkgInfo
    , profiles # : Attrset Profile
    , buildCrateOverrides # : Attrset (Attrset _)
    , buildRustCrate # : Attrset -> Derivation
    , registries # : Attrset Registry

    # FIXME: Cross compilation.
    , rustc
    , stdenv
    }:
    let

      getPkgInfo = { source ? null, name, version, ... }@args: let
        m = match "(registry|git)\\+([^#]*).*" source;
        kind = elemAt m 0;
        url = elemAt m 1;
      in
        # Local crates have no `source`.
        if source == null then
          localSrcInfos.${toPkgId args}
            or (throw "Local crate is outside the workspace: ${toPkgId args}")
          // { isLocalPkg = true; }
        else if m == null then
          throw "Invalid source: ${source}"
        else if kind == "registry" then
          getPkgInfoFromIndex
            (registries.${url} or
              (throw "Registry `${url}` not found. Please define it in `extraRegistries`."))
            args
          // { inherit source; } # `source` is for crate id, which is used for overrides.
        else if kind == "git" then
          (gitSrcInfos.${url}
            or (throw "Git source `${url}` not found. Please define it in `gitSrcs`.")).${name}
            or (throw "Crate `${name}` not found in git source `${url}`")
        else
          throw "Invalid source: ${source}";

      hostCfgs = platformToCfgs stdenv.hostPlatform;

      pkgSetRaw = resolveDepsFromLock getPkgInfo lock;
      pkgSet = mapAttrs (id: info: info // {
        dependencies = map (dep: dep // {
          targetEnabled = dep.target != null -> evalTargetCfgStr hostCfgs dep.target;
        }) info.dependencies;
      }) pkgSetRaw;

      selectDeps = pkgs: deps: enabledDeps: selectKind: onlyLinks:
        map
          (dep: { rename = dep.rename or null; drv = pkgs.${dep.resolved}; })
          (filter
            ({ kind, name, optional, targetEnabled, resolved, ... }@dep:
              targetEnabled && kind == selectKind
              && (optional -> elem name enabledDeps)
              && (if resolved == null then throw "Unresolved dependency: ${toJSON dep}" else true)
              && (onlyLinks -> pkgSet.${resolved}.links != null))
            deps);

      buildRustCrate' = info: args:
        let
          args' = args // (info.__override or lib.id) args;
          args'' = args' // (buildCrateOverrides.${toPkgId info} or lib.id) args';
        in
          buildRustCrate args'';

      mkPkg = profile: rootId: makeOverridable (
        { features }:
        let
          rootFeatures = if features != null then features
            else if pkgSet.${rootId}.features ? default then [ "default" ]
            else [];

          resolvedBuildFeatures = resolveFeatures {
            inherit pkgSet rootId rootFeatures;
            depFilter = dep: dep.targetEnabled && (dep.kind == "normal" || dep.kind == "build");
          };
          resolvedNormalFeatures = resolveFeatures {
            inherit pkgSet rootId rootFeatures;
            depFilter = dep: dep.targetEnabled && dep.kind == "normal";
          };

          pkgsBuild = mapAttrs (id: { features, deps }: let info = pkgSet.${id}; in
            buildRustCrate' info {
              inherit (info) version src;
              manifest = info.manifest or null;
              crateSubdir = info.crateSubdir or null;
              inherit features profile rustc;
              pname = info.name;
              capLints = if localSrcInfos ? ${id} then null else "allow";
              buildDependencies = selectDeps pkgsBuild info.dependencies deps "build" false;
              # Build dependency's normal dependency is still build dependency.
              dependencies = selectDeps pkgsBuild info.dependencies deps "normal" false;
              linksDependencies = selectDeps pkgsBuild info.dependencies deps "normal" true;
            }
          ) resolvedBuildFeatures;

          pkgs = mapAttrs (id: { features, deps }: let info = pkgSet.${id}; in
            buildRustCrate' info {
              inherit (info) version src links;
              manifest = info.manifest or null;
              crateSubdir = info.crateSubdir or null;
              inherit features profile rustc;
              pname = info.name;
              capLints = if localSrcInfos ? ${id} then null else "allow";
              buildDependencies = selectDeps pkgsBuild info.dependencies deps "build" false;
              dependencies = selectDeps pkgs info.dependencies deps "normal" false;
              linksDependencies = selectDeps pkgs info.dependencies deps "normal" true;
            }
          ) resolvedNormalFeatures;
        in
          pkgs.${rootId}
      ) {
        features = null;
      };

    in
      mapAttrs (_: profile:
        mapAttrs' (pkgId: pkgInfo: {
          name = pkgInfo.name;
          value = mkPkg profile pkgId;
        }) localSrcInfos
      ) profiles;

  sanitizeRelativePath = path:
    if hasPrefix "/" path then
      throw "Absolute path is not allowed: ${path}"
    else
      concatStringsSep "/"
        (filter
          (s:
            isString s && s != "" && s != "." &&
            (if match ''.*[[?*].*|\.\.'' s != null then throw ''
              Globing and `..` are not allowed: ${path}
            '' else true))
          (split ''[\/]'' path));

  build-from-src-dry-tests = { assertEq, pkgs, defaultRegistries, ... }: let
    inherit (builtins) head listToAttrs;

    mkPackage = pkgs.callPackage mkRustPackageOrWorkspace {
      inherit defaultRegistries;
      buildRustCrate = args: args;
    };

    build = src: args:
      head (attrValues (mkPackage ({ inherit src; } // args)).dev);

  in
  {
    features = let ret = build ../tests/features {}; in
      assertEq ret.features [ "a" "default" "semver" ]; # FIXME

    dependency-features = let
      ret = build ../tests/features { };
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in assertEq
      [ semver.features serde.features ]
      [ [ "default" "serde" "std" ] [ /* Don't trigger default features */ ] ];

    dependency-overrided = let
      ret = build ../tests/features {
        buildCrateOverrides."" = old: { a = "b"; };
        buildCrateOverrides."serde 1.0.139 (registry+https://github.com/rust-lang/crates.io-index)" = old: {
          buildInputs = [ "some-inputs" ];
        };
      };
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in
      assertEq serde.buildInputs [ "some-inputs" ];

    dependency-kinds = let
      mkSrc = from: { __toString = _: ../tests/fake-semver; inherit from; };
      gitSrcs = {
        "https://github.com/dtolnay/semver?tag=1.0.0" = mkSrc "tag";
        "http://github.com/dtolnay/semver" = mkSrc "branch"; # v1, v2
        "http://github.com/dtolnay/semver?branch=master" = mkSrc "branch"; # v3
        "ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd" = mkSrc "rev";
        "ssh://git@github.com/dtolnay/semver" = mkSrc "nothing";
      };
      extraRegistries = {
        "https://www.github.com/rust-lang/crates.io-index" =
          head (attrValues defaultRegistries);
      };

      ret = build ../tests/dependency-v3 {
        inherit gitSrcs extraRegistries;
      };
      ret' = listToAttrs
        (map (dep: {
          name = if dep.rename != null then dep.rename else dep.drv.pname;
          value = dep.drv.src.from or dep.drv.src.name;
        }) ret.dependencies);
    in
      assertEq ret' {
        cratesio = "crate-semver-1.0.12.tar.gz";
        git_branch = "branch";
        git_head = "nothing";
        git_rev = "rev";
        git_tag = "tag";
        registry_index = "crate-semver-1.0.12.tar.gz";
      };

    libz-propagated = let
      ret = build ../tests/libz-dynamic {};
      libz = (head ret.dependencies).drv;
    in
      assertEq (head libz.propagatedBuildInputs).pname "zlib";

    libz-link = let
      ret = build ../tests/libz-dynamic {};
      libz = (head ret.dependencies).drv;
      libz' = (head ret.linksDependencies).drv;
    in
      assertEq [ libz.links libz'.links ] [ "z" "z" ];
  };

  sanitize-relative-path-tests = { assertEq, ... }: let
    assertOk = raw: expect: assertEq (tryEval (sanitizeRelativePath raw)) { success = true; value = expect; };
    assertInvalid = raw: assertEq (tryEval (sanitizeRelativePath raw)) { success = false; value = false; };
  in
  {
    empty = assertOk "" "";
    simple1 = assertOk "foo" "foo";
    simple2 = assertOk "foo/bar" "foo/bar";
    dot1 = assertOk "." "";
    dot2 = assertOk "./././" "";
    dot3 = assertOk "./foo/./bar/" "foo/bar";

    dotdot1 = assertInvalid "..";
    dotdot2 = assertInvalid "./foo/..";
    dotdot3 = assertInvalid "../bar";
    root1 = assertInvalid "/";
    root2 = assertInvalid "/foo";
  };
}
