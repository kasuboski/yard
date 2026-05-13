Mono repo for Ballast and Chute.

Chute is a language tailored for LLM generation. Read knowledge/chute.md to learn more.
Ballast is the runtime for Chute. It takes in the Chute code provides the capabilities for the effects defined in Chute and executes the code.

Both projects use gleam with the erlang target. mise and mise.toml provide the environment setup.

Development flow:
- gleam format
- gleam check
- gleam test
