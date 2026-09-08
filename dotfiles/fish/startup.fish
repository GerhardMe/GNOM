if status is-interactive
    # Diable welcome msg:
    set -g fish_greeting

    # PATH scripts
    set -gx PATH $HOME/.local/bin $PATH

    # ----------------------------------------------------------------
    # ------------------ Git auto commit messages --------------------
    # ----------------------------------------------------------------

    function git
        set -l subcmd $argv[1]
        switch $subcmd
            case c
                # git c <msg>  → use <msg> as commit message
                # git c        → auto-commit with timestamp
                if test (count $argv) -gt 1
                    command git commit -m "$argv[2..-1]"
                else
                    command git commit -m (date '+%Y-%m-%d %H:%M:%S')
                end

            case lts
                set -l ts (date '+%Y-%m-%d %H:%M:%S')
                command git commit -m "lts: $ts"

            case p
                command git push

            case a
                set -l ts (date '+%Y-%m-%d %H:%M:%S')
                command git add .
                command git commit -m "lts: $ts"
                command git push

            case ac
                set -l ts (date '+%Y-%m-%d %H:%M:%S')
                command git add .
                if test (count $argv) -gt 1
                    command git commit -m "$argv[2..-1]"
                else
                    command git commit -m "lts: $ts"
                end
                command git push

            case '*'
                # any other git command, just pass through
                command git $argv
        end
    end

    # ----------------------------------------------------------------
    # ------------------------------ !! ------------------------------
    # ----------------------------------------------------------------

    function bind_bang
        switch (commandline -t)
            case "!"
                commandline -t $history[1]
                commandline -f repaint
            case "*"
                commandline -i !
        end
    end

    function bind_dollar
        switch (commandline -t)
            case "!"
                commandline -t ""
                commandline -f history-token-search-backward
            case "*"
                commandline -i '$'
        end
    end

    function fish_user_key_bindings
        bind ! bind_bang
        bind '$' bind_dollar
    end

    # ----------------------------------------------------------------
    # -------------------- Functions for idiots ----------------------
    # ----------------------------------------------------------------

    function month
        set -l cur (date +%m)

        printf "\e[38;5;27m01 January (31)";   test "$cur" = "01"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;27m02 February (28/29)"; test "$cur" = "02"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;40m03 March (31)";     test "$cur" = "03"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;40m04 April (30)";     test "$cur" = "04"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;40m05 May (31)";       test "$cur" = "05"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;226m06 June (30)";     test "$cur" = "06"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;226m07 July (31)";     test "$cur" = "07"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;226m08 August (31)";   test "$cur" = "08"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;208m09 September (30)"; test "$cur" = "09"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;208m10 October (31)";   test "$cur" = "10"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;208m11 November (30)";  test "$cur" = "11"; and printf " <--"; printf "\e[0m\n"
        printf "\e[38;5;27m12 December (31)";   test "$cur" = "12"; and printf " <--"; printf "\e[0m\n"
    end

    # ----------------------------------------------------------------
    # ----------------------------- Aliases --------------------------
    # ----------------------------------------------------------------

    function dev
        # Build (not enter) the devShell first to create a persistent GC
        # root under ~/.cache/gnoms/shells, so garbage collection can't
        # wipe the shell of a project you're in. Refreshed on every run.
        mkdir -p "$HOME/.cache/gnoms/shells"
        nix build --no-link --out-link "$HOME/.cache/gnoms/shells/"(basename "$PWD") \
            ".#devShells."(nix config show system)".default" 2>/dev/null
        nix develop --command fish $argv
    end

    # Reconfigure
    alias reload='reconfigure reload'
    alias rebuild='reconfigure rebuild'
    alias upgrade='reconfigure upgrade'
    alias update='reconfigure update'

    # Fun
    alias minecraft='egpu prismlauncher'
    alias quarium='asciiquarium --transparent'

    # Misc
    alias try='nix-shell -p'
    alias man='batman'
    alias neofetch='fastfetch'
    alias fetch='fastfetch'

end
