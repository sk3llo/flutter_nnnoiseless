## Getting Started

1. Generate rust bridge bindings

```
flutter_rust_bridge_codegen integrate
```

2. We need to execute the code generator whenever the Rust code is changed, or use --watch to automatically re-generate when code changes:

```
flutter_rust_bridge_codegen generate --watch
```
