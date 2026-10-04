module App
  # Checks every write to @@MODEL@@: its slug is the first path segment of
  # every page that belongs to it, so it must be a lowercase DNS label that
  # no other @@LABEL@@ and no central route uses.
  class @@MODEL@@::Changeset < SugarORM::Changeset(App::@@MODEL@@)
    param name : String
    param slug : String

    def validate(cs)
      cs.validate_presence(:name)
      cs.validate_tenant_slug(:slug)
      cs.unique_constraint(:slug)
    end
  end

  alias @@MODEL@@::CreateChangeset = @@MODEL@@::Changeset
  alias @@MODEL@@::UpdateChangeset = @@MODEL@@::Changeset
end
