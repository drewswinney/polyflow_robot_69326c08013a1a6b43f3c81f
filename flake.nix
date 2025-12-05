{
  description = "NixOS (Pi 4) + ROS 2 Humble + prebuilt colcon workspace";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://ros.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };

  ##############################################################################
  # Inputs
  ##############################################################################
  inputs = {
    nix-ros-overlay.url = "github:lopsided98/nix-ros-overlay";
    nix-ros-overlay.flake = false;
    nixpkgs.url = "github:lopsided98/nixpkgs/nix-ros";
    poetry2nix.url = "github:nix-community/poetry2nix";
    poetry2nix.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nix-ros-workspace.url = "github:hacker1024/nix-ros-workspace";
    nix-ros-workspace.flake = false;
  };

  ##############################################################################
  # Outputs
  ##############################################################################
  outputs = { self, nixpkgs, poetry2nix, nixos-hardware, nix-ros-workspace, nix-ros-overlay, ... }:
  let
    system = "aarch64-linux";

    # Overlay: pin python3 -> python312 (ROS Humble Python deps are happy here)
    pinPython312 = final: prev: {
      python3         = prev.python312;
      python3Packages = prev.python312Packages;
    };

        # ROS overlay setup from nix-ros-overlay (non-flake)
    rosBase = import nix-ros-overlay { inherit system; };

    rosOverlays =
      if builtins.isFunction rosBase then
        # Direct overlay function
        [ rosBase ]
      else if builtins.isList rosBase then
        # Already a list of overlay functions
        rosBase
      else if rosBase ? default && builtins.isFunction rosBase.default then
        # Attrset with a `default` overlay
        [ rosBase.default ]
      else if rosBase ? overlays && builtins.isList rosBase.overlays then
        # Attrset with `overlays = [ overlay1 overlay2 … ]`
        rosBase.overlays
      else if rosBase ? overlays
           && rosBase.overlays ? default
           && builtins.isFunction rosBase.overlays.default then
        # Attrset with `overlays.default` as the primary overlay
        [ rosBase.overlays.default ]
      else
        throw "nix-ros-overlay: unexpected structure; expected an overlay or list of overlays";

    rosWorkspaceOverlay = (import nix-ros-workspace { inherit system; }).overlay;
    
    pkgs = import nixpkgs {
      inherit system;
      overlays = rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
    };

    poetry2nixPkgs = poetry2nix.lib.mkPoetry2Nix { inherit pkgs; };

    lib     = pkgs.lib;
    rosPkgs = pkgs.rosPackages.humble;

    ############################################################################
    # Workspace discovery
    ############################################################################

    # Prefer a workspace folder within the repo; fall back to common sibling paths.
    workspaceCandidates = [
      ./workspace
      ../workspace
    ];
    
    workspaceRoot =
      let existing = builtins.filter builtins.pathExists workspaceCandidates;
      in if existing != [ ] then builtins.head existing else
        throw "workspace directory not found; expected one of: "
          + (builtins.concatStringsSep ", " (map (p: builtins.toString p) workspaceCandidates));

    workspaceSrcPath =
      let path = "${workspaceRoot}/src";
      in if builtins.pathExists path then path else
        throw "workspace src not found at ${path}";

    webrtcSrc = pkgs.lib.cleanSourceWith {
      src = builtins.path { path = builtins.toString (./workspace) + "/src/webrtc"; name = "webrtc-src"; };
      filter = path: type:
        # include typical project files; drop bytecode and VCS junk
        !(pkgs.lib.hasSuffix ".pyc" path)
        && !(pkgs.lib.hasInfix "/__pycache__/" path)
        && !(pkgs.lib.hasInfix "/.git/" path);
    };

    webrtcEnv = poetry2nixPkgs.mkPoetryEnv {
      projectDir = webrtcSrc;
      preferWheels = true;
      python = py;
    };

    # Robot Console static assets (expects dist/ already built in ./robot-console)
    robotConsoleSrc = builtins.path { path = ./robot-console; name = "robot-console-src"; };

    robotConsoleStatic = pkgs.stdenv.mkDerivation {
      pname = "robot-console";
      version = "0.1.0";
      src = robotConsoleSrc;
      dontUnpack = true;
      dontBuild = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p $out/dist
        if [ -d "$src/dist" ]; then
          cp -rT "$src/dist" "$out/dist"
        else
          echo "robot-console dist/ not found; run npm install && npm run build in robot-console before building the image." >&2
          exit 1
        fi
      '';
    };

    # Robot API (FastAPI) packaged from ./robot-api
    robotApiSrc = pkgs.lib.cleanSource ./robot-api;
    robotApiPkg = pkgs.python3Packages.buildPythonPackage {
      pname = "robot-api";
      version = "0.1.0";
      src = robotApiSrc;
      format = "pyproject";
      propagatedBuildInputs = with pkgs.python3Packages; [
        fastapi
        uvicorn
        pydantic
        psutil
        websockets
      ];
      nativeBuildInputs = [
        pkgs.python3Packages.setuptools
        pkgs.python3Packages.wheel
      ];
    };

    ############################################################################
    # ROS 2 workspace (Humble)
    ############################################################################

    rosPackageDirs =
      let
        entries = builtins.readDir workspaceSrcPath;
        filtered = lib.filterAttrs (name: v: v == "directory" && name != "webrtc") entries;
      in builtins.trace
        ''polyflow-ros: found ROS dirs ${lib.concatStringsSep ", " (lib.attrNames filtered)} under ${workspaceSrcPath}''
        filtered;

    rosPoetryDeps = lib.genAttrs (lib.filter (pkg: builtins.pathExists "${workspaceSrcPath}/${pkg}/poetry.lock")
                  (lib.attrNames rosPackageDirs)) (pkg:
      poetry2nixPkgs.mkPoetryEnv {
        projectDir = "${workspaceSrcPath}/${pkg}";
        python = py;
        preferWheels = true;
        # keep the ROS package itself editable; we only want its PyPI deps here
        editablePackageSources."${pkg}" = "${workspaceSrcPath}/${pkg}";
      });

    isAmentPythonPkg = name:
      let base = "${workspaceSrcPath}/${name}";
      in builtins.pathExists "${base}/setup.py"
         || builtins.pathExists "${base}/pyproject.toml";

    rosWorkspacePackages = lib.mapAttrs (name: _: rosPkgs.buildRosPackage (
      let
        # Broad ROS runtime so user packages have common messages/tools without per-package mapping.
        defaultRosRuntime = with rosPkgs; [
          ros-base
          rclpy
          launch
          launch-ros
          ament-index-python
          composition-interfaces
          std-msgs
          sensor-msgs
          trajectory-msgs
          geometry-msgs
          nav-msgs
        ] ++ [
          pkgs.python3Packages.pyyaml
        ];
      in {
        pname = name;
        # Make the derivation name deterministic even if package.xml parsing fails.
        version = "0.0.1";
        src   = pkgs.lib.cleanSource "${workspaceSrcPath}/${name}";
        # Pure Python/ament packages don't emit separate debug outputs; keep only "out".
        outputs = [ "out" ];
        # Avoid auto-adding a "debug" output (not emitted by most ROS packages here).
        separateDebugInfo = false;
        propagatedBuildInputs =
          (lib.optionals (isAmentPythonPkg name) defaultRosRuntime)
          ++ lib.optionals (rosPoetryDeps ? name) [ rosPoetryDeps.${name} ];
      }
      // lib.optionalAttrs (isAmentPythonPkg name) {
        # Force Python packages down the ament_python path so setup.py runs.
        buildType = "ament_python";
      }
      // lib.optionalAttrs (isAmentPythonPkg name) {
        # Provide the libexec shim ROS expects for ament_python packages.
        postInstall = ''
          mkdir -p "$out/lib/${name}"
          if [ -d "$out/bin" ]; then
            for exe in "$out/bin"/*; do
              [ -f "$exe" ] || continue
              ln -sf "$exe" "$out/lib/${name}/$(basename "$exe")"
              # Ensure AMENT/PYTHON/LD_LIBRARY paths are seeded for direct execution
              wrapProgram "$exe" \
                --set-default AMENT_PREFIX_PATH "${lib.concatStringsSep ":" (map (pkg: "${pkg}") (with rosPkgs; [ ros-base rmw-cyclonedds-cpp rmw-implementation ]))}:$out" \
                --suffix AMENT_PREFIX_PATH ":" "$AMENT_PREFIX_PATH" \
                --set-default PYTHONPATH "$out/lib/python${pkgs.python3.pythonVersion}/site-packages" \
                --suffix PYTHONPATH ":" "$PYTHONPATH" \
                --set-default LD_LIBRARY_PATH "$out/lib" \
                --suffix LD_LIBRARY_PATH ":" "$LD_LIBRARY_PATH"
            done
          fi
        '';
      })) rosPackageDirs;
    
    # Avoid the double "-workspace" suffix that buildROSWorkspace adds
    rosWorkspace = rosPkgs.buildROSWorkspace {
      name = "polyflow-ros";
      devPackages = rosWorkspacePackages;
      # Pass the attrset (not a list) so buildROSWorkspace can merge dependencies.
      prebuiltPackages = rosPoetryDeps;
    };

    rosWorkspaceEnv = pkgs.buildEnv {
      name = "polyflow-ros-env";
      paths = [ rosWorkspace ];
    };

    # Python (ROS toolchain) + helpers
    py = pkgs.python3;
    pyPkgs = py.pkgs or pkgs.python3Packages;
    sp = py.sitePackages;

    # Build a fixed osrf-pycommon (PEP 517), reusing nixpkgs' source
    osrfSrc = pkgs.python3Packages."osrf-pycommon".src;

    osrfFixed = pyPkgs.buildPythonPackage {
      pname        = "osrf-pycommon";
      version      = "2.0.2";
      src          = osrfSrc;
      pyproject    = true;
      build-system = [ py.pkgs.setuptools py.pkgs.wheel ];
      doCheck      = false;
    };

    # Minimal Python environment for running webrtc + ROS Python bits
    pyEnv = py.withPackages (ps: [
      ps.pyyaml
      ps.empy
      ps.catkin-pkg
      osrfFixed
    ]);

    ############################################################################
    # WebRTC (Python) package for robot
    ############################################################################
     webrtcPkg = pkgs.python3Packages.buildPythonPackage {
      pname   = "webrtc";
      version = "0.0.1";
      # Point this at the folder that contains package.xml, setup.py, resource/, launch/, and the Python pkg dir `webrtc/`
      src     = webrtcSrc;

      format  = "setuptools";

      dontUseCmakeConfigure = true;
      dontUseCmakeBuild     = true;
      dontUseCmakeInstall   = true;
      dontWrapPythonPrograms = true;

      nativeBuildInputs = [
        pkgs.python3Packages.setuptools
      ];

      # Python/ROS runtime deps your node imports (expand as needed)
      propagatedBuildInputs = with rosPkgs; [
        rclpy
        launch
        launch-ros
        ament-index-python
        composition-interfaces
      ] ++ [
        pkgs.python3Packages.pyyaml
      ];

      # After the Python install, add the ROS "ament index" marker, share files, and the libexec shim
      postInstall = ''
        set -euo pipefail

        # 1: ament index registration
        mkdir -p $out/share/ament_index/resource_index/packages
        echo webrtc > $out/share/ament_index/resource_index/packages/webrtc

        # 2: package share (package.xml + launch)
        mkdir -p $out/share/webrtc/
        cp ${webrtcSrc}/package.xml $out/share/webrtc/
        cp ${webrtcSrc}/webrtc.launch.py $out/share/webrtc

        # If you keep a resource marker, install it too (recommended)
        if [ -f ${webrtcSrc}/resource/webrtc ]; then
          install -Dm644 ${webrtcSrc}/resource/webrtc $out/share/webrtc/resource
        fi

        # 3: libexec shim so launch_ros finds the executable under lib/webrtc/webrtc_node
        mkdir -p $out/lib/webrtc
        cat > $out/lib/webrtc/webrtc_node <<'EOF'
#!${pkgs.bash}/bin/bash
exec ${pkgs.python3}/bin/python3 -m webrtc.node "$@"
EOF
        chmod +x $out/lib/webrtc/webrtc_node
    '';
    };
  in
  {
    # Export packages
    packages.${system} = {
      webrtcPkg        = webrtcPkg;
      robotConsoleStatic = robotConsoleStatic;
      robotApiPkg      = robotApiPkg;
      rosWorkspace     = rosWorkspace;
      rosWorkspaceEnv  = rosWorkspaceEnv;
    };

    # Full NixOS config for Pi 4 (sd-image)
    nixosConfigurations.rpi4 = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit webrtcPkg webrtcEnv pyEnv robotConsoleStatic robotApiPkg rosWorkspace rosWorkspaceEnv;
      };
      modules = [
        ({ ... }: {
          nixpkgs.overlays =
            rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
        })
        nixos-hardware.nixosModules.raspberry-pi-4
        ./configuration.nix
      ];
    };
  };
}
