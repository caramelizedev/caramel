module App
  struct @@MODEL@@Input
    include Caramel::FormInput
    form_envelope "@@SINGULAR@@"
@@MODEL_FIELDS@@
  end
end
