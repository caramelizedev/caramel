require "../caramel/version"
require "./commands"

module Caramel::Frappe
  # `frappe completion zsh|bash|fish`: a script that completes commands,
  # subcommands, options and choices, generated from Commands::TABLE.
  module Completion
    # What may follow a run of command words: a word (with its line), or an option.
    # value: the option takes a value; joined: it is written --name=VALUE, so no space follows.
    record Candidate, word : String, description : String, value : Bool, joined : Bool

    # Each run of command words ("" for none) with its candidates, in TABLE order.
    # Every command is a node, even one with no candidates, so that the walk
    # stops at `db restore` and offers file names instead of db's subcommands.
    def self.nodes : Hash(String, Array(Candidate))
      nodes = {"" => [] of Candidate}
      Commands::TABLE.each do |command|
        command.words.each_index do |depth|
          add(nodes, command.words[0, depth].join(' '),
            Candidate.new(command.words[depth], Commands.brief(command.words[0, depth + 1]),
              false, false))
        end
        nodes[command.name] ||= [] of Candidate
        command.positionals.each do |positional|
          positional.choices.try &.each do |choice|
            add(nodes, command.name, Candidate.new(choice, "", false, false))
          end
        end
        command.flags.each do |flag|
          flag.names.each do |name|
            candidate = if flag.equals
                          Candidate.new("#{name}=", "", true, true)
                        elsif flag.value
                          Candidate.new(name, "", true, false)
                        else
                          Candidate.new(name, "", false, false)
                        end
            add(nodes, command.name, candidate)
          end
        end
      end
      nodes
    end

    def self.script(shell : String) : String
      nodes = self.nodes
      case shell
      when "zsh"  then zsh(nodes)
      when "bash" then bash(nodes)
      when "fish" then fish(nodes)
      else
        raise ArgumentError.new("no completion script for #{shell}")
      end
    end

    private def self.add(nodes : Hash(String, Array(Candidate)), node : String,
                         candidate : Candidate) : Nil
      candidates = (nodes[node] ||= [] of Candidate)
      candidates << candidate unless candidates.any?(&.word.==(candidate.word))
    end

    # POSIX single quoting, which zsh, bash and fish all read the same.
    private def self.quote(text : String) : String
      "'" + text.gsub("'", "'\\''") + "'"
    end

    # Every node but the root, quoted: the runs of words the walk may extend.
    private def self.keys(nodes : Hash(String, Array(Candidate))) : Array(String)
      nodes.keys.reject(&.empty?).map { |key| quote(key) }
    end

    private def self.bash(nodes : Hash(String, Array(Candidate))) : String
      String.build do |io|
        io << "# frappe completion for bash, from Frappé #{Caramel::VERSION}.\n"
        io << "# Load it from ~/.bashrc: source <(frappe completion bash)\n"
        io << <<-BASH
          _frappe() {
            local cur=${COMP_WORDS[COMP_CWORD]} node='' next='' i=1 candidates=''
            if [[ ${COMP_WORDS[1]} == help && $COMP_CWORD -gt 1 ]]; then i=2; fi
            while ((i < COMP_CWORD)); do
              next="${node:+$node }${COMP_WORDS[i]}"
              case $next in

          BASH
        io << "      " << keys(nodes).join('|') << ") node=$next ;;\n"
        io << <<-BASH
                *) break ;;
              esac
              i=$((i + 1))
            done
            case $node in

          BASH
        nodes.each do |node, candidates|
          io << "    " << quote(node) << ") candidates=" <<
            quote(candidates.join(' ', &.word)) << " ;;\n"
        end
        io << <<-BASH
            esac
            # bash splits --name=VALUE at `=`: nothing in the table completes a value.
            if [[ $cur == = || ${COMP_WORDS[COMP_CWORD-1]} == = ]]; then return 0; fi
            COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
            if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
              COMPREPLY=($(compgen -f -- "$cur"))
            elif [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == *= ]]; then
              type compopt >/dev/null 2>&1 && compopt -o nospace
            fi
          }
          complete -F _frappe frappe

          BASH
      end
    end

    # The variable is `node`, never `path`: zsh ties `path` to PATH.
    private def self.zsh(nodes : Hash(String, Array(Candidate))) : String
      String.build do |io|
        io << "#compdef frappe\n"
        io << "# frappe completion for zsh, from Frappé #{Caramel::VERSION}.\n"
        io << "# Load it from ~/.zshrc after compinit: source <(frappe completion zsh)\n"
        io << <<-ZSH
          _frappe() {
            local node='' next=''
            local -i i=2 ret=1
            local -a described joined
            if [[ ${words[2]} == help && $CURRENT -gt 2 ]]; then i=3; fi
            while (( i < CURRENT )); do
              next="${node:+$node }${words[i]}"
              case $next in

          ZSH
        io << "      (" << keys(nodes).join('|') << ") node=$next ;;\n"
        io << <<-ZSH
                (*) break ;;
              esac
              i=$((i + 1))
            done
            case $node in

          ZSH
        nodes.each do |node, candidates|
          words, joined = candidates.partition { |candidate| !candidate.joined }
          io << "    (" << quote(node) << ") described=("
          io << words.join(' ') { |candidate| described(candidate) }
          io << "); joined=("
          io << joined.join(' ') { |candidate| quote(candidate.word) }
          io << ") ;;\n"
        end
        io << <<-ZSH
            esac
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
      end
    end

    private def self.described(candidate : Candidate) : String
      return quote(candidate.word) if candidate.description.empty?
      quote("#{candidate.word}:#{candidate.description}")
    end

    # `-f` appears only on `-a` lines, so a node whose candidates are all options
    # still completes file names.
    private def self.fish(nodes : Hash(String, Array(Candidate))) : String
      String.build do |io|
        io << "# frappe completion for fish, from Frappé #{Caramel::VERSION}.\n"
        io << "# Install it: frappe completion fish > ~/.config/fish/completions/frappe.fish\n"
        io << "set -g __frappe_nodes " << keys(nodes).join(' ') << "\n"
        io << <<-FISH
          function __frappe_at --argument-names expected
              set -l tokens (commandline -opc)
              set -e tokens[1]
              if test (count $tokens) -gt 0; and test "$tokens[1]" = help
                  set -e tokens[1]
              end
              set -l node ''
              for word in $tokens
                  set -l next (string trim -- "$node $word")
                  if contains -- $next $__frappe_nodes
                      set node $next
                  else
                      break
                  end
              end
              test "$node" = "$expected"
          end

          FISH
        nodes.each do |node, candidates|
          candidates.each do |candidate|
            io << "complete -c frappe"
            if candidate.word.starts_with?("--")
              name = candidate.word.lstrip('-').rchop('=')
              io << " -n \"__frappe_at '" << node << "'\" -l " << name
              io << " -r" if candidate.value
            else
              io << " -f -n \"__frappe_at '" << node << "'\" -a " << quote(candidate.word)
              io << " -d " << quote(candidate.description) unless candidate.description.empty?
            end
            io << '\n'
          end
        end
      end
    end
  end
end
