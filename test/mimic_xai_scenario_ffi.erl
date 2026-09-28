-module(mimic_xai_scenario_ffi).
-export([sha256/1]).

sha256(Bytes) -> crypto:hash(sha256, Bytes).
