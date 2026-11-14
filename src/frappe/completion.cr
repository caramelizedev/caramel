require "../caramel/version"
require "./commands"

module Caramel::Frappe
  # Completion of commands, subcommands, options and choices from a command table.
  # `frappe completion zsh|bash|fish` prints a script that asks Frappé, each time the
  # shell completes, for what may follow the words typed so far: `frappe __complete
  # WORD…`. Frappé answers from the commands of the directory it runs in, so a project's
  # shards complete beside the built-ins.
  module Completion
    # The hidden command the scripts call. No table lists it: a command word has no `_`.
    COMMAND = "__complete"

    # What may follow a run of command words: a word (with its line), or an option.
    # An option written --name=VALUE ends in `=`, so that no space follows it.
    record Candidate, word : String, description : String

    # Each run of command words ("" for none) with its candidates, in the table's order.
    # Every command is a node, even one with no candidates, so that the walk
    # stops at `db restore` and offers file names instead of db's subcommands.
    def self.nodes(table : Commands::Table) : Hash(String, Array(Candidate))
      nodes = {"" => [] of Candidate}
      table.commands.each do |command|
        command.words.each_index do |depth|
          add(nodes, command.words[0, depth].join(' '),
            Candidate.new(command.words[depth], table.brief(command.words[0, depth + 1])))
        end
        nodes[command.name] ||= [] of Candidate
        command.positionals.each do |positional|
          positional.choices.try &.each do |choice|
            add(nodes, command.name, Candidate.new(choice, ""))
          end
        end
        command.flags.each do |flag|
          flag.names.each do |name|
            add(nodes, command.name, Candidate.new(flag.equals ? "#{name}=" : name, ""))
          end
        end
      end
      nodes
    end

    # What follows *words*, the words typed after `frappe`: the last is the one under the
    # cursor, which the shell matches itself. `help` completes as the commands it explains.
    def self.candidates(table : Commands::Table, words : Array(String)) : Array(Candidate)
      nodes = self.nodes(table)
      before = words.empty? ? words : words[0...-1]
      before = before[1..] if before.first? == "help"
      node = ""
      before.each do |word|
        extended = node.empty? ? word : "#{node} #{word}"
        break unless nodes.has_key?(extended)
        node = extended
      end
      nodes[node]
    end

    # The candidates for *words* as the scripts read them: one to a line, a tab before
    # the description of a candidate that has one.
    def self.answer(table : Commands::Table, words : Array(String)) : String
      String.build do |io|
        candidates(table, words).each do |candidate|
          io << candidate.word
          io << '\t' << candidate.description unless candidate.description.empty?
          io << '\n'
        end
      end
    end

    # The script that completes `frappe` in *shell* by asking Frappé for the candidates.
    def self.script(shell : String) : String
      case shell
      when "zsh"  then ZSH_HEADER + ZSH
      when "bash" then BASH_HEADER + BASH
      when "fish" then FISH_HEADER + FISH
      else
        raise ArgumentError.new("no completion script for #{shell}")
      end
    end

    private def self.add(nodes : Hash(String, Array(Candidate)), node : String,
                         candidate : Candidate) : Nil
      candidates = (nodes[node] ||= [] of Candidate)
      candidates << candidate unless candidates.any?(&.word.==(candidate.word))
    end

    private BASH_HEADER = <<-TEXT
      # frappe completion for bash, from Frappé #{Caramel::VERSION}.
      # Load it from ~/.bashrc: eval "$(frappe completion bash)"\n
      TEXT

    # bash breaks a word at `:` and `=` and replaces only what follows the break, so the
    # script puts the pieces back together for Frappé and offers each candidate without
    # the part of the word that bash already holds.
    private BASH = <<-'BASH'
      _frappe() {
        local cur='' held='' word='' description='' glued=0 i
        local -a typed
        for ((i = 1; i <= COMP_CWORD; i++)); do
          word=${COMP_WORDS[i]}
          if [[ $i -gt 1 && -n $word && ( -z ${word//[:=]/} || $glued == 1 ) ]]; then
            typed[${#typed[@]}-1]+=$word
          else
            typed+=("$word")
          fi
          if [[ -n $word && -z ${word//[:=]/} ]]; then glued=1; else glued=0; fi
        done
        cur=${typed[${#typed[@]}-1]}
        # Nothing completes the VALUE of --name=VALUE.
        if [[ $cur == -*=* ]]; then return 0; fi
        if [[ $cur == *:* && $COMP_WORDBREAKS == *:* ]]; then held=${cur%"${cur##*:}"}; fi
        COMPREPLY=()
        while IFS=$'\t' read -r word description; do
          if [[ -n $word && $word == "$cur"* ]]; then COMPREPLY+=("${word#"$held"}"); fi
        done < <("${COMP_WORDS[0]}" __complete "${typed[@]}" 2>/dev/null)
        if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
          COMPREPLY=($(compgen -f -- "${cur#"$held"}"))
        elif [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == *= ]]; then
          type compopt >/dev/null 2>&1 && compopt -o nospace
        fi
      }
      complete -F _frappe frappe

      BASH

    private ZSH_HEADER = <<-TEXT
      #compdef frappe
      # frappe completion for zsh, from Frappé #{Caramel::VERSION}.
      # Load it from ~/.zshrc after compinit: source <(frappe completion zsh)\n
      TEXT

    # _describe reads word:description, so a `:` inside the word is escaped. A candidate
    # that ends in `=` is written --name=VALUE, so no space follows it.
    private ZSH = <<-'ZSH'
      _frappe() {
        local word='' description=''
        local -i ret=1
        local -a described joined
        while IFS=$'\t' read -r word description; do
          if [[ -z $word ]]; then continue; fi
          if [[ $word == *= ]]; then
            joined+=("$word")
          elif [[ -n $description ]]; then
            described+=("${word//:/\\:}:$description")
          else
            described+=("${word//:/\\:}")
          fi
        done < <("${words[1]}" __complete "${(@)words[2,CURRENT]}" 2>/dev/null)
        if (( ${#described} )); then
          _describe -t frappe-commands 'frappe' described && ret=0
        fi
        if (( ${#joined} )); then compadd -S '' -- "${joined[@]}" && ret=0; fi
        (( ret )) && _files
        return 0
      }
      if [[ ${funcstack[1]} == _frappe ]]; then
        _frappe "$@"
      else
        compdef _frappe frappe
      fi

      ZSH

    private FISH_HEADER = <<-TEXT
      # frappe completion for fish, from Frappé #{Caramel::VERSION}.
      # Install it: frappe completion fish > ~/.config/fish/completions/frappe.fish\n
      TEXT

    # fish reads word<TAB>description and keeps shard:command as one word. It would match
    # the description too, so the script offers the words that begin as the one typed,
    # in Frappé's order. File names are offered unless Frappé offers a word: a command
    # or a choice, not an option.
    private FISH = <<-FISH
      function __frappe_answer
          set -l words (commandline -opc)
          set -l frappe $words[1]
          set -e words[1]
          set -l current (commandline -ct)
          $frappe __complete $words "$current" 2>/dev/null
      end
      function __frappe_candidates
          set -l typed (string escape --style=regex -- (commandline -ct))
          __frappe_answer | string match -r -- "^$typed.*"
      end
      function __frappe_offers_words
          __frappe_answer | string match -q -r -v -- '^-'
      end
      complete -c frappe -n __frappe_offers_words -f
      complete -c frappe -k -a '(__frappe_candidates)'

      FISH
  end
end
