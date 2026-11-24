.PHONY: setup verifier build test test-solidity bench fmt clean version version-check

version:  ## Print project version and Git revision
	python3 scripts/version.py

version-check:  ## Check release metadata (optional TAG=v0.1.0)
	python3 scripts/version.py --check $(if $(TAG),--tag $(TAG))

setup:  ## Download checksum-pinned tools and forge-std into .tools/
	python3 scripts/toolchain.py setup

verifier:  ## make verifier CIRCUIT=target/c.json OUT=V.fe  (or VK=path/vk instead of CIRCUIT)
	python3 scripts/generate.py $(if $(CIRCUIT),-b $(CIRCUIT),-k $(VK)) -o $(OUT)

build:  ## Compile probes, fixture verifiers and the Solidity test suite
	python3 scripts/build.py
	python3 scripts/toolchain.py forge build --offline

test:  ## Everything: Fe tests, compile-fail, native proofs, Forge differential
	python3 scripts/test.py

test-solidity: build  ## Build artifacts, then run Forge (optional FORGE_ARGS='--match-contract CurveTest')
	python3 scripts/toolchain.py forge test --offline --no-match-contract BenchTest $(FORGE_ARGS)

bench:  ## Size and gas against Barretenberg's Solidity verifier
	python3 scripts/bench.py

fmt:  ## Format Fe, Solidity tests and Python tooling
	python3 scripts/toolchain.py fe fmt src
	python3 scripts/toolchain.py fe fmt tests/probes/src
	python3 scripts/toolchain.py fe fmt tests/compile_fail
	python3 scripts/toolchain.py forge fmt tests/solidity
	python3 scripts/toolchain.py ruff format scripts
	python3 scripts/toolchain.py ruff check --fix scripts

clean:
	rm -rf out cache .ruff_cache scripts/__pycache__
