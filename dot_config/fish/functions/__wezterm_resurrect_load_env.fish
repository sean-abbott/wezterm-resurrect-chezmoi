function __wezterm_resurrect_load_env --argument-names file --description 'Internal: reload KEY=VALUE lines from a file into the environment'
    test -r "$file"; or return 1

    for line in (string split \n -- (cat -- "$file"))
        set line (string trim -- $line)
        test -z "$line"; and continue
        string match -qr '^\s*#' -- $line; and continue

        set -l kv (string split -m1 '=' -- $line)
        test (count $kv) -eq 2; or continue

        set -l key (string trim -- $kv[1])
        set -l val (string trim -- $kv[2])

        set -gx $key $val
    end
end
