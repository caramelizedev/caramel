module App
  # Checks every write to @@MODEL@@: App::@@MODEL@@.create inserts through it and
  # record.update updates through it. Replace an alias with its own class when
  # creating and updating need different params or rules.
  class @@MODEL@@::Changeset < SugarORM::Changeset(App::@@MODEL@@)
@@PARAMS@@

    def validate(cs)
@@VALIDATIONS@@
    end
  end

  alias @@MODEL@@::CreateChangeset = @@MODEL@@::Changeset
  alias @@MODEL@@::UpdateChangeset = @@MODEL@@::Changeset
end
