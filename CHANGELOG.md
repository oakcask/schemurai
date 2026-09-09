# Changelog

## [2.2.1](https://github.com/oakcask/schemurai/compare/v2.2.0...v2.2.1) (2026-09-09)


### Bug Fixes

* preserve RBS types in generated docs ([#101](https://github.com/oakcask/schemurai/issues/101)) ([75d56b2](https://github.com/oakcask/schemurai/commit/75d56b29afa82e642937080eb9efc027b09e0bba))

## [2.2.0](https://github.com/oakcask/schemurai/compare/v2.1.0...v2.2.0) (2026-09-02)


### Features

* ship public RBS signatures ([#82](https://github.com/oakcask/schemurai/issues/82)) ([6b1295e](https://github.com/oakcask/schemurai/commit/6b1295ee35643893fa935a3f153e8ff04bcddc9b))


### Performance Improvements

* accelerate VM annotation evaluation ([#85](https://github.com/oakcask/schemurai/issues/85)) ([d128b94](https://github.com/oakcask/schemurai/commit/d128b9498aff4d164915c7febcf701284b7c0780))
* consolidate VM rule presence fields ([c0f3426](https://github.com/oakcask/schemurai/commit/c0f342606b6121946eed42cb11c34887d3e85c95))
* emit VM instructions directly ([#88](https://github.com/oakcask/schemurai/issues/88)) ([793a4f7](https://github.com/oakcask/schemurai/commit/793a4f70d7c5a9b94db1469c4cfb80d6b8ccf2f6))
* improve vm backend throughput ([#83](https://github.com/oakcask/schemurai/issues/83)) ([fcd736c](https://github.com/oakcask/schemurai/commit/fcd736cce4a88199a4055449e5a55433a1dda24d))
* improve VM build performance ([#89](https://github.com/oakcask/schemurai/issues/89)) ([64af485](https://github.com/oakcask/schemurai/commit/64af4852bbe4b82db1d11990bd4b52257b8a5238))
* improve vm validation performance ([#80](https://github.com/oakcask/schemurai/issues/80)) ([911f168](https://github.com/oakcask/schemurai/commit/911f168c893ea705fbe465779ca35606da67ffc9))
* optimize newer draft validation ([#86](https://github.com/oakcask/schemurai/issues/86)) ([f71daac](https://github.com/oakcask/schemurai/commit/f71daac3a033a938ef60f2e214e912b4a4632d26))
* reduce VM validation allocations ([#84](https://github.com/oakcask/schemurai/issues/84)) ([b1ec79b](https://github.com/oakcask/schemurai/commit/b1ec79bf0c6b70f8cf884f3d113e0f0a5b51fd9e))

## [2.1.0](https://github.com/oakcask/schemurai/compare/v2.0.0...v2.1.0) (2026-09-01)


### Features

* improve validation error messages ([#77](https://github.com/oakcask/schemurai/issues/77)) ([48b992a](https://github.com/oakcask/schemurai/commit/48b992a1f752acd78c03f2e491eed1006ed5d9c0))


### Bug Fixes

* run release lockfile workflow on PR creation ([#79](https://github.com/oakcask/schemurai/issues/79)) ([aa8fbb0](https://github.com/oakcask/schemurai/commit/aa8fbb0a4b251278eee3c91aa433991ddb32e22d))

## [2.0.0](https://github.com/oakcask/schemurai/compare/v1.0.0...v2.0.0) (2026-09-01)


### ⚠ BREAKING CHANGES

* backend: :bytecode and SCHEMURAI_BACKEND=bytecode are removed; use backend: :vm and SCHEMURAI_BACKEND=vm.
* Ruby 3.2 and 3.3 are no longer supported.

### Features

* add meta-schema validation ([#74](https://github.com/oakcask/schemurai/issues/74)) ([5dfbed8](https://github.com/oakcask/schemurai/commit/5dfbed8b15f9336e30beba2dbac1b4fab8b1cdeb))
* add native evaluator ([#56](https://github.com/oakcask/schemurai/issues/56)) ([eccfd90](https://github.com/oakcask/schemurai/commit/eccfd905f1690b459b92532a0ff8bd1cc206a963))
* add Ruby bytecode backend ([#60](https://github.com/oakcask/schemurai/issues/60)) ([ea53485](https://github.com/oakcask/schemurai/commit/ea5348589a1975bdd8463a675ef44dfb81b91022))
* freeze bytecode program inputs ([#61](https://github.com/oakcask/schemurai/issues/61)) ([898a409](https://github.com/oakcask/schemurai/commit/898a4095e524251bd9d99f2d913a834aaca50c88))
* freeze native backend oracle contract ([#47](https://github.com/oakcask/schemurai/issues/47)) ([b8f6274](https://github.com/oakcask/schemurai/commit/b8f62747fd259f5e2569e49461d31a4f2c2e0d68))


### Performance Improvements

* avoid empty prefix item arrays ([#65](https://github.com/oakcask/schemurai/issues/65)) ([a3527ea](https://github.com/oakcask/schemurai/commit/a3527ea09622369ddee722a2d73ba7bba7762dc5))
* cache native evaluator constants ([#57](https://github.com/oakcask/schemurai/issues/57)) ([ad2a43b](https://github.com/oakcask/schemurai/commit/ad2a43ba504f4722dbdfa253ac2b9120731e370a))
* compile bytecode content flags ([#69](https://github.com/oakcask/schemurai/issues/69)) ([78f194a](https://github.com/oakcask/schemurai/commit/78f194a1ea576656ac8ce61d64dddac76928f9de))
* compile bytecode type checks ([#64](https://github.com/oakcask/schemurai/issues/64)) ([ec0e4f6](https://github.com/oakcask/schemurai/commit/ec0e4f6ea7c5d9f06e91704ac9b12b4a46a0b5b3))
* compile numeric bytecode rules ([#63](https://github.com/oakcask/schemurai/issues/63)) ([506932b](https://github.com/oakcask/schemurai/commit/506932b05d2485d69d4147ed8770dc6569235c85))
* compile reference bytecode opcodes ([#66](https://github.com/oakcask/schemurai/issues/66)) ([cf9c0e2](https://github.com/oakcask/schemurai/commit/cf9c0e2182a78b92c460a518958edfb8598c3c4f))
* fix bytecode rule layouts ([#67](https://github.com/oakcask/schemurai/issues/67)) ([7294f98](https://github.com/oakcask/schemurai/commit/7294f9808ab1f49c72ec5b91043de6e203224f12))
* localize bytecode dynamic scope ([#68](https://github.com/oakcask/schemurai/issues/68)) ([64724de](https://github.com/oakcask/schemurai/commit/64724dee21ef9d4a1b0f0507e34b991482e52647))
* optimize native evaluator hot paths ([#58](https://github.com/oakcask/schemurai/issues/58)) ([0e7bc96](https://github.com/oakcask/schemurai/commit/0e7bc96226c20b41e13989b5cf452eaeea337efd))
* share VM bytecode across validators ([10ea6cc](https://github.com/oakcask/schemurai/commit/10ea6ccee2dd6d5d0c06625f1ce4436c58f3336a))


### Miscellaneous Chores

* test package on maintained Rubies ([#45](https://github.com/oakcask/schemurai/issues/45)) ([4e37b08](https://github.com/oakcask/schemurai/commit/4e37b08553162d0dfeecaae518da99f296c72c76))


### Code Refactoring

* rename bytecode backend to vm ([#71](https://github.com/oakcask/schemurai/issues/71)) ([78dfce1](https://github.com/oakcask/schemurai/commit/78dfce110cc2de018a135a5e35d775ea64cde85e))

## 1.0.0 (2026-08-31)


### ⚠ BREAKING CHANGES

* replace require "json_schema_validator" with require "schemurai" and replace JsonSchemaValidator references with Schemurai.
* compile now returns Validator instead of CompiledSchema, Validator construction no longer accepts CompiledSchema, and compile keyword-schema shorthand is removed.
* `JsonSchemaValidator::Error` is now the base exception. Validation result entries previously represented by that data type are now `JsonSchemaValidator::ValidationError`.

### Features

* add draft 7 implementation and benchmark ([4f4423f](https://github.com/oakcask/schemurai/commit/4f4423fb90b285b8e838fc6ddcbc5cfd85c1eedd))
* add shareable schema registries ([#35](https://github.com/oakcask/schemurai/issues/35)) ([485f895](https://github.com/oakcask/schemurai/commit/485f89521d289729790e2aed0ee1aca7787be880))
* enable IPv4 format validation tests ([#19](https://github.com/oakcask/schemurai/issues/19)) ([3d88aef](https://github.com/oakcask/schemurai/commit/3d88aef3dfaeada000879435f512ea070451d542))
* implement duration, UUID, and JSON Pointer formats ([#20](https://github.com/oakcask/schemurai/issues/20)) ([8a25578](https://github.com/oakcask/schemurai/commit/8a25578a3aac78f0882af3bd99bcb43641e30bd3))
* share compiled schema registries across validators ([#10](https://github.com/oakcask/schemurai/issues/10)) ([59497ae](https://github.com/oakcask/schemurai/commit/59497ae55c3fd6a9140b3eddd9e58a2cc23b78f5))
* support draft 2019-09 and 2020-12 ([#9](https://github.com/oakcask/schemurai/issues/9)) ([d0fc395](https://github.com/oakcask/schemurai/commit/d0fc395da72273a63cd031368c995f9a8e22042b))
* support IPv6 format validation ([#27](https://github.com/oakcask/schemurai/issues/27)) ([b962495](https://github.com/oakcask/schemurai/commit/b962495944484922eda300552b3f2c9f314c4267))
* validate RFC 3339 date and time formats ([#18](https://github.com/oakcask/schemurai/issues/18)) ([aed0571](https://github.com/oakcask/schemurai/commit/aed057188208e0699e9f01333b2a92557bfe657c))


### Bug Fixes

* keep constants private ([#4](https://github.com/oakcask/schemurai/issues/4)) ([48c0f44](https://github.com/oakcask/schemurai/commit/48c0f4460348166ef9f22f7d635b64a07a3a7239))
* keep SchemaGraph unchanged after compile errors ([#31](https://github.com/oakcask/schemurai/issues/31)) ([7e3b4b1](https://github.com/oakcask/schemurai/commit/7e3b4b103e894b2b5233795b194e04a5c2585e73))
* reject unsupported assertion formats ([#21](https://github.com/oakcask/schemurai/issues/21)) ([43a0ea0](https://github.com/oakcask/schemurai/commit/43a0ea01b5b2e550c7bcf120f975dcf81b83e761))
* resolve RuboCop leaky local variables ([#33](https://github.com/oakcask/schemurai/issues/33)) ([7cf73f9](https://github.com/oakcask/schemurai/commit/7cf73f90a3fd32776db403ffa5904e99ce99c105))


### Performance Improvements

* avoid URI.join if unecessary ([eaefbb7](https://github.com/oakcask/schemurai/commit/eaefbb7913fe481ba640f940e4caec7d0e9e557e))
* cache external documents ([39b6e28](https://github.com/oakcask/schemurai/commit/39b6e28650e9ae2ca3e9a4e7b0b30c9210ee28ee))
* defer validation error pointer generation ([#43](https://github.com/oakcask/schemurai/issues/43)) ([552abd9](https://github.com/oakcask/schemurai/commit/552abd944ec7091d3e042fabbe50ee1ece400bea))
* improve performance ([4faafab](https://github.com/oakcask/schemurai/commit/4faafab4f0e7620d2e2311452d5f22ce7ef845bd))
* reduce object allocations ([#2](https://github.com/oakcask/schemurai/issues/2)) ([8566619](https://github.com/oakcask/schemurai/commit/8566619022756b7cf53d11ce8b84678df43187c2))
* skip unused dynamic scope tracking ([#12](https://github.com/oakcask/schemurai/issues/12)) ([f576d59](https://github.com/oakcask/schemurai/commit/f576d59a563c7f186b124a04a0da0b0ec8e1ed21))
* use nested hash for schema children ([#15](https://github.com/oakcask/schemurai/issues/15)) ([23e392a](https://github.com/oakcask/schemurai/commit/23e392ad72cdcebe91b7460500646cd98aa6e328))
* use nested hashes for schema graph indexes ([#26](https://github.com/oakcask/schemurai/issues/26)) ([6426dd4](https://github.com/oakcask/schemurai/commit/6426dd476dddb58068378b3d5adb575fbc45e213))


### Code Refactoring

* rename gem to schemurai ([#37](https://github.com/oakcask/schemurai/issues/37)) ([8ca2751](https://github.com/oakcask/schemurai/commit/8ca2751ee33d45012fa46859ec67bb85c3bd228b))
* return validators from compile ([#32](https://github.com/oakcask/schemurai/issues/32)) ([5a24430](https://github.com/oakcask/schemurai/commit/5a244309f027bddea3c17b9a43432cde8a8d90fe))
