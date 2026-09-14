# Commands that must affect the current container shell run locally.
if test "$BH_ENV_ACTIVE" = 1; and not functions -q act
    function act --description 'Activate the current directory virtual environment'
        if test -f .venv/bin/activate.fish
            source .venv/bin/activate.fish
        else
            printf 'act: .venv/bin/activate.fish is missing in %s\n' "$PWD" >&2
            return 1
        end
    end
end
