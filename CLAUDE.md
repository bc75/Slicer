# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

3D Slicer: a C++/Qt/VTK/ITK application with an embedded Python layer, built as a CMake "superbuild".
This clone is a fork of `slicer/slicer` `main` at github.com/bc75/Slicer (`upstream` remote = slicer/slicer).
The local goal is a native arm64 build on macOS.

## Building (macOS arm64, this machine)

- One-shot native build: `Utilities/Scripts/BuildSlicerMacOSArm64.sh` (env: `SLICER_BUILD_DIR`, default
  `/opt/sr`; `JOBS`, default 4; `DEPLOYMENT_TARGET`, default 14.0). It installs Homebrew Qt 6 if missing, builds a
  native `CTKAppLauncher` first, then configures and builds Slicer.
- Superbuild layout: `<build>/` builds VTK, ITK, CTK, Python, ... and then the inner project in
  `<build>/Slicer-build`. After the first full build, rebuild only the inner project:
  `make -C /opt/sr/Slicer-build -j4`. Never build in-source; keep the build path short (mach-o load-command
  limit), e.g. `/opt/sr`.
- Key configure flags: `-DCMAKE_OSX_ARCHITECTURES=arm64` (OpenSSL picks its target from it),
  `-DQt6_DIR=/opt/homebrew/lib/cmake/Qt6` (defining `Qt6_DIR` selects the Qt 6.8 minimum),
  `-DSlicer_USE_SYSTEM_QT=ON` (Homebrew's prefix is not auto-detected as system Qt, and without it the launcher
  pushes Qt dirs onto `DYLD_LIBRARY_PATH`), `-DCTKAppLauncher_DIR=<native launcher install>` (upstream only ships
  an x86_64 launcher for macOS, `SuperBuild/External_CTKAPPLAUNCHER.cmake`).
- Run: `/opt/sr/Slicer-build/Slicer` (the launcher sets `DYLD_*`/`PYTHONPATH`, then starts
  `bin/Slicer.app/Contents/MacOS/SlicerApp-real`). Useful flags: `--no-splash --no-main-window --testing
  --exit-after-startup --python-script f.py --python-code "..." --disable-cli-modules --additional-module-paths d`.
- Build options: `Docs/developer_guide/build_instructions/overview.md`; the macOS page has the arm64 recipe and
  the error catalogue. Extensions build out-of-tree against a built Slicer (`Extensions/CMake`).

## Testing

- From the inner build dir: `cd /opt/sr/Slicer-build && ctest -j4`. One test: `ctest -R <regex>
  --output-on-failure`; by kit label: `ctest -L MRMLCore`; list: `ctest -N`.
- C++ tests are registered with `simple_test()` / `slicerMacroConfigureModuleCxxTestDriver()` into a per-kit
  driver, runnable directly as `bin/<KIT>CxxTests <TestName>`.
- Python tests are named `py_<ScriptName>` and run the launcher with `--no-splash --testing --python-code
  "import slicer.testing; slicer.testing.runUnitTest([...], '<Name>')"` (`CMake/SlicerMacroPythonTesting.cmake`).
  A scripted module's `<Name>Test(ScriptedLoadableModuleTest)` class becomes a ctest via
  `slicer_add_python_unittest(SCRIPT <Name>.py)` in its CMakeLists.
- Test data are `.md5`/`.sha256` content links resolved by `CMake/ExternalData.cmake` (`DATA{...}` arguments)
  and downloaded from SlicerTestingData releases into `<build>/ExternalData/Objects`.

## Lint, format, docs

- `pre-commit run --all-files` (or `--files <paths>`): ruff (`.ruff.toml`, py312, line length 320),
  clang-format 23 (`.clang-format`: Mozilla base, Allman braces, `ColumnLimit: 180`, `InsertBraces`, includes
  are not sorted), pyupgrade `--py312-plus`, prettier for YAML, standard hygiene hooks.
- Spelling: `Utilities/Scripts/runCodespell.sh` (needs codespell and yq); ignore list in `.codespellignore`.
- Docs: `pip install -r requirements-docs.txt && cd Docs && make html`.
- Git hooks and rebase config: `./Utilities/SetupForDevelopment.sh` (does not install pre-commit).

## Commit messages

Subject must start with `BUG:`, `COMP:`, `DOC:`, `ENH:`, `PERF:`, `STYLE:` or `WIP:` (CI-enforced), imperative
mood, capitalized, no trailing period, ideally under 50 chars and never over 72; body wrapped at 80.

## Architecture

Build/dependency order enforced in `CMakeLists.txt`: `Libs` -> `Base` (Logic, QTCore, QTGUI, QTCLI) ->
`Modules/Core` -> `Base/QTApp` -> `Modules` -> `Applications`.

- `Libs/MRML/Core`: `vtkMRMLScene` / `vtkMRML*Node` (VTK+ITK only, no Qt, no Logic). `Libs/MRML/Logic`:
  `vtkMRMLAbstractLogic`. `Libs/MRML/DisplayableManager`: per-view `vtkMRML*DisplayableManager`, instantiated by
  class name through `vtkMRML{ThreeDView,SliceView}DisplayableManagerFactory`. `Libs/MRML/Widgets`: `qMRML*`.
  Also `vtkITK`, `vtkTeem`, `vtkSegmentationCore`, `RemoteIO`; `vtkAddon` is an external project.
- `Base/`: `SlicerBaseLogic` -> `qSlicerBaseQTCore` (`qSlicerCoreApplication`, module factory managers) ->
  `qSlicerBaseQTGUI` (`qSlicerApplication`, layout manager) and `qSlicerBaseQTCLI` -> `qSlicerBaseQTApp`
  (`qSlicerMainWindow`, `qSlicerApplicationHelper` = the startup sequence and factory registration order:
  core, loadable, scripted, CLI, then the `Modules/AdditionalPaths` setting). `Applications/SlicerApp/Main.cxx`
  is intentionally tiny and is the template for derived apps.
- Dependency rule: MRML nodes depend only on VTK/ITK; Logic depends on MRML; GUI may depend on MRML, Logic, Qt.
  Naming: `vtkMRML*Node`, `vtkSlicer*Logic`, `vtkMRML*DisplayableManager`, `qSlicer*` (app/module GUI),
  `qMRML*` (widgets bound to a node or scene).
- Logic lifecycle: `SetMRMLScene` -> `SetMRMLSceneInternal` (declare observed scene events) -> `RegisterNodes`
  (`scene->RegisterNodeClass`) -> `ObserveMRMLScene`/`UpdateFromMRMLScene`; then `ProcessMRMLSceneEvents`
  (`OnMRMLSceneNodeAdded`, ...) and `ProcessMRMLNodesEvents` (`OnMRMLNodeModified`).
- Module kinds (templates in `Utilities/Templates/Modules`, generated by `Utilities/Scripts/ModuleWizard.py`):
  - Loadable C++ (`Modules/Loadable/X`): `qSlicerXModule` Qt plugin (`setup()` registers displayable
    managers), `qSlicerXModuleWidget` + `Resources/UI/*.ui`, `Logic/vtkSlicerXLogic`, optional `MRML/`,
    `MRMLDM/`, `Widgets/`, `SubjectHierarchyPlugins/`; macros in `CMake/SlicerMacroBuild*.cmake`.
    Small example `Modules/Loadable/Reformat`; full example `Modules/Loadable/Markups`.
  - CLI (`Modules/CLI/X`): `X.xml` descriptor + `X.cxx` using `PARSE_ARGS`, built with `SEMMacroBuildCLI`
    (SlicerExecutionModel); run out of process by default. Example `ThresholdScalarVolume`.
  - Scripted (`Modules/Scripted/X/X.py`): classes `X(ScriptedLoadableModule)`, `XWidget`, `XLogic`, `XTest`;
    `slicerMacroBuildScriptedModule` in CMakeLists. Example `LineProfile` (uses `parameterNodeWrapper`).
- Python: VTK classes get VTK wrapping, Qt classes get PythonQt (`WRAP_PYTHONQT`, extra methods in
  `*PythonQtDecorators.h`); the generated `Base/Python/slicer/kits.py` star-imports both so everything is flat in
  the `slicer` namespace. `Base/Python/slicer/util.py` holds the helpers (`getNode`, `loadVolume`,
  `arrayFromVolume`, ...); `slicerqt.py` wires `slicer.modules.<name>`, `slicer.app`, `slicer.mrmlScene`.
- Conventions: world space is RAS in millimeters; strings are UTF-8; VTK classes report with
  `vtkErrorMacro`/`vtkWarningMacro`, Qt classes with `qCritical`/`qWarning`; keep `VTK_DEBUG_LEAKS` clean;
  includes: own header first, then groups module -> MRML -> CTK -> Qt -> VTK -> ITK -> STL, each with a
  `// <Lib> includes` comment. Style guide: `Docs/developer_guide/style_guide.md`.
