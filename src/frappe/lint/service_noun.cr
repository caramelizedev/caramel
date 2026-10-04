module Ameba::Rule::Caramel
  # Reports types named for a service noun, such as `InvitationService`,
  # `TeamMemberInvitationServiceHandler` or `AbstractDataTransformerFactory`.
  #
  # Subjects act on objects directly, so the verb belongs on
  # its subject (`team.invite(...)`, a changeset or a job), not on an
  # intermediary noun that exists only to hold it.
  #
  # ```
  # class InvitationService   # reported
  # struct Teams::Invite < Caramel::Action
  # ```
  class ServiceNoun < Base
    properties do
      description "Disallows service-noun type names"
      suffixes %w[Service Handler Manager Factory Controller Helper Util Utils Utility]
      prefixes %w[Abstract]
    end

    MSG = "`%s` is a service noun; put the verb on its subject instead, " \
          "e.g. a method on the model, a changeset or a job"

    def test(source, node : Crystal::ClassDef | Crystal::ModuleDef)
      name = node.name.names.last
      return unless noun?(name)

      issue_for(node.name, MSG % name)
    end

    private def noun?(name : String) : Bool
      suffixes.any? { |suffix| name != suffix && name.ends_with?(suffix) } ||
        prefixes.any? { |prefix| prefixed?(name, prefix) }
    end

    # Whether *name* is *prefix* followed by a capitalized word, as in
    # `AbstractDataTransformerFactory`.
    private def prefixed?(name : String, prefix : String) : Bool
      name.size > prefix.size && name.starts_with?(prefix) && name[prefix.size].uppercase?
    end
  end
end
