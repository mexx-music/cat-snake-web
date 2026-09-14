{{flutter_js}}
{{flutter_build_config}}

const catSnakeVersion =
  new URLSearchParams(window.location.search).get('v') || Date.now().toString();
const catSnakeBuild = _flutter.buildConfig.builds.find(
  (build) => build.mainJsPath,
);
if (catSnakeBuild) {
  catSnakeBuild.mainJsPath =
    `${catSnakeBuild.mainJsPath}?v=${encodeURIComponent(catSnakeVersion)}`;
}

_flutter.loader.load();
