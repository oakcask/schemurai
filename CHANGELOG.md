# Changelog

## [3.0.1](https://github.com/oakcask/schemurai/compare/v3.0.0...v3.0.1) (2026-10-12)


### Performance Improvements

* use native NEON Base64 packing for ARM64 content ([#198](https://github.com/oakcask/schemurai/issues/198)) ([99c38f2](https://github.com/oakcask/schemurai/commit/99c38f2b73ec574f37c97974bf0b9d3ff31a4e19))
* vectorize native integer array bounds ([#200](https://github.com/oakcask/schemurai/issues/200)) ([27a18b2](https://github.com/oakcask/schemurai/commit/27a18b2b48382c954b053de02a65f5368338292c))
* vectorize native pattern UTF-8 validation ([#201](https://github.com/oakcask/schemurai/issues/201)) ([6d2200e](https://github.com/oakcask/schemurai/commit/6d2200e6e15ddbc967ba2ecfa1c1204f12ed6478))
* vectorize native UUID format validation ([#199](https://github.com/oakcask/schemurai/issues/199)) ([9591fd3](https://github.com/oakcask/schemurai/commit/9591fd3d94665282963870667afec3b3a773ccbd))

## [3.0.0](https://github.com/oakcask/schemurai/compare/v2.3.0...v3.0.0) (2026-10-12)


### ⚠ BREAKING CHANGES

* Schemurai requires Ruby 4.0 or later; Ruby 3.4 is no longer supported.

### Features

* add opt-in error caps and cooperative timeouts ([#190](https://github.com/oakcask/schemurai/issues/190)) ([a375bbb](https://github.com/oakcask/schemurai/commit/a375bbbbc5909777830ba4e0f07b58ae92a67f29))


### Bug Fixes

* drop Ruby 3.4 support for compiler GC safety ([#178](https://github.com/oakcask/schemurai/issues/178)) ([9f69db3](https://github.com/oakcask/schemurai/commit/9f69db3f268930d0f526d708e1e14fa3c00e292d))


### Performance Improvements

* bound native property annotation storage to occupied words ([#170](https://github.com/oakcask/schemurai/issues/170)) ([3cacc23](https://github.com/oakcask/schemurai/commit/3cacc231f9e6ec125f1e70a58a6aabea59ebe615))
* bound native unique index probing ([#192](https://github.com/oakcask/schemurai/issues/192)) ([fb351ab](https://github.com/oakcask/schemurai/commit/fb351ab89c4cbc68f7c4452b41685ba2ba11fae4))
* hash all wide integer digits in native fingerprints ([#181](https://github.com/oakcask/schemurai/issues/181)) ([2b9a147](https://github.com/oakcask/schemurai/commit/2b9a1472ef866069c55b171b44cec8d01219922d))
* index native dynamic binding discovery ([#187](https://github.com/oakcask/schemurai/issues/187)) ([bc7407e](https://github.com/oakcask/schemurai/commit/bc7407ef7fcd4bd6e3b17a8b2907dd1486bea087))
* index native enum candidates ([#166](https://github.com/oakcask/schemurai/issues/166)) ([e413010](https://github.com/oakcask/schemurai/commit/e41301029b52dc8665dbf1206f1ccb13e9cc2261))
* index native required and property joins during compilation ([#174](https://github.com/oakcask/schemurai/issues/174)) ([2439118](https://github.com/oakcask/schemurai/commit/2439118f50754a628ce49c6e090d076423d7966b))
* keep native dynamic binding compilation sparse ([#184](https://github.com/oakcask/schemurai/issues/184)) ([439d227](https://github.com/oakcask/schemurai/commit/439d227222fbfb819a387bf5937d5d685167b514))
* keep native memoization active after cache saturation ([#180](https://github.com/oakcask/schemurai/issues/180)) ([05d6494](https://github.com/oakcask/schemurai/commit/05d6494b72db920ccfb9cbfa52ae1b289bfbccff))
* keep shallow native fingerprint traversal inexpensive ([#197](https://github.com/oakcask/schemurai/issues/197)) ([aaa82fa](https://github.com/oakcask/schemurai/commit/aaa82fad8cdd5ddb17b05b474f48b33de14a4fb0))
* memoize native graphs with invariant dynamic references ([#182](https://github.com/oakcask/schemurai/issues/182)) ([7307b40](https://github.com/oakcask/schemurai/commit/7307b407466019e91418d2053b07a8d4f1968336))
* memoize native reference cycles by guard context ([#188](https://github.com/oakcask/schemurai/issues/188)) ([1bc9ef2](https://github.com/oakcask/schemurai/commit/1bc9ef2a1083f097db50c5152ff7d9d65b38587a))
* memoize native root property cycles ([#191](https://github.com/oakcask/schemurai/issues/191)) ([2ccd362](https://github.com/oakcask/schemurai/commit/2ccd362299d2f87555144d060fba010d7b5f4e24))
* memoize repeated native instance positions ([#186](https://github.com/oakcask/schemurai/issues/186)) ([222d31b](https://github.com/oakcask/schemurai/commit/222d31b7cf40c81393055d08e67d84981584b39f))
* memoize shared native graphs by effective dynamic scope ([#183](https://github.com/oakcask/schemurai/issues/183)) ([c1c9fe2](https://github.com/oakcask/schemurai/commit/c1c9fe228ddd6051949d6d078481323fc0405514))
* memoize shared native reference annotations ([#176](https://github.com/oakcask/schemurai/issues/176)) ([22f87c9](https://github.com/oakcask/schemurai/commit/22f87c973d27090742f946b17617f440cbc8b0a2))
* memoize shared static native reference targets per invocation ([#171](https://github.com/oakcask/schemurai/issues/171)) ([32b0dcc](https://github.com/oakcask/schemurai/commit/32b0dcca5f6079b438ce49f5033983336fa16f49))
* preserve shared schema operand graphs during compilation ([#196](https://github.com/oakcask/schemurai/issues/196)) ([8a3f05b](https://github.com/oakcask/schemurai/commit/8a3f05b6ee44cd3b9d742e5d0e7a9a91bf72e119))
* project native memo keys onto reachable scope bindings ([#193](https://github.com/oakcask/schemurai/issues/193)) ([6fa0d24](https://github.com/oakcask/schemurai/commit/6fa0d243d992909ffa28722f2faafe93da73edba))
* reuse native fingerprints across unique item batches ([#195](https://github.com/oakcask/schemurai/issues/195)) ([83e8bf7](https://github.com/oakcask/schemurai/commit/83e8bf7dcd8194ccf5ecc685be82755c29b9bc66))
* reuse shared native container traversals ([#185](https://github.com/oakcask/schemurai/issues/185)) ([c6f126f](https://github.com/oakcask/schemurai/commit/c6f126f0edfe163e16ace716332c9b1b5cfd2b73))
* scan anchored native property patterns with a shared DFA ([#172](https://github.com/oakcask/schemurai/issues/172)) ([197bb04](https://github.com/oakcask/schemurai/commit/197bb0491b46127b880871394027b626e843bcdf))
* share guarded instance kinds across native applicators ([#169](https://github.com/oakcask/schemurai/issues/169)) ([4550080](https://github.com/oakcask/schemurai/commit/455008026fc094a1dc26857901674fc0a7ef6bd7))
* share native compilation across Ractors ([#167](https://github.com/oakcask/schemurai/issues/167)) ([d60fa35](https://github.com/oakcask/schemurai/commit/d60fa35412a8dc6a1b11ee1c6b133b0c6f5f8879))
* stop proven native contains predicates when bounds are conclusive ([#173](https://github.com/oakcask/schemurai/issues/173)) ([2e2beb4](https://github.com/oakcask/schemurai/commit/2e2beb4f1a987c3179d10fb187a361258f50e36b))

## [2.3.0](https://github.com/oakcask/schemurai/compare/v2.2.3...v2.3.0) (2026-10-11)


### Features

* add optional Rust native backend and architecture benchmarks ([#159](https://github.com/oakcask/schemurai/issues/159)) ([3076170](https://github.com/oakcask/schemurai/commit/3076170b09a9eefe8c86ded5c1b1a264520fc087))

## [2.2.3](https://github.com/oakcask/schemurai/compare/v2.2.2...v2.2.3) (2026-10-07)


### Performance Improvements

* optimize VM evaluation tracking ([#152](https://github.com/oakcask/schemurai/issues/152)) ([835943e](https://github.com/oakcask/schemurai/commit/835943e92e5231b3644ce13f4fd495cfe842bb60))

## [2.2.2](https://github.com/oakcask/schemurai/compare/v2.2.1...v2.2.2) (2026-10-07)


### Bug Fixes

* use gemspec Ruby requirement ([#124](https://github.com/oakcask/schemurai/issues/124)) ([167e3d3](https://github.com/oakcask/schemurai/commit/167e3d3d82809f0029ae81224389c5dcec12e7ed))


### Performance Improvements

* index unique items by JSON fingerprints ([#150](https://github.com/oakcask/schemurai/issues/150)) ([61cd425](https://github.com/oakcask/schemurai/commit/61cd4252f0cb7895328e31287476368ee2a48b69))
* reduce unique items allocations ([#151](https://github.com/oakcask/schemurai/issues/151)) ([c4f6f77](https://github.com/oakcask/schemurai/commit/c4f6f77a8cd5ac111f10622b4b92eaa47eb12916))

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
