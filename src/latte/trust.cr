require "./toolchain"
require "./state_format"
require "./proxy"
require "./server"
require "digest/sha256"

module Caramel::Latte
  # Trust is a per-user operation. The privileged port/DNS installer never
  # receives CA private keys and never modifies the system trust store.
  class Trust
    RECEIPT_FORMAT = 1

    def initialize(@paths : Paths,
                   @proxy : Proxy,
                   @toolchain : Toolchain = Toolchain.for_checkout)
    end

    def fingerprint : String
      fingerprint_of(File.read(certificate_path))
    end

    def install : Nil
      certificate = File.read(certificate_path)
      digest = fingerprint_of(certificate)
      saved = receipt
      if saved && saved["sha256"].as_s != digest
        message = "Remove the previously installed Latte certificate " \
                  "before rotating its authority"
        raise PublicError.new("ca_changed", message)
      end
      keychain = saved ? saved["keychain"].as_s : default_keychain
      # Record a public certificate snapshot before installation, making
      # interrupted installation and later removal refer to the same CA.
      ConfigFile.directory(trust_directory)
      ConfigFile.write(snapshot, certificate)
      write_receipt(digest, keychain, "pending")
      command = ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
                 "-k", keychain, snapshot]
      result = ProcessRunner.run(command, timeout: 60.seconds)
      unless result.success?
        message = "macOS did not install the local certificate trust; " \
                  "retry Latte HTTPS setup"
        raise PublicError.new("trust_failed", message)
      end
      write_receipt(digest, keychain, "installed")
    end

    def remove : Nil
      saved = receipt
      return unless saved
      keychain = saved["keychain"].as_s
      result = @toolchain.run(:openssl, ["x509", "-in", snapshot, "-outform", "DER"])
      unless result.success? && Digest::SHA256.hexdigest(result.stdout) == saved["sha256"].as_s
        raise PublicError.new("ca_changed", "Saved Latte certificate changed; trust was preserved")
      end
      # The fingerprint selects this exact certificate, without deleting any
      # other local developer tool's authority from the keychain.
      digest = saved["sha256"].as_s.upcase
      command = ["/usr/bin/security", "delete-certificate", "-t", "-Z", digest, keychain]
      result = ProcessRunner.run(command, timeout: 60.seconds)
      unless result.success?
        message = "macOS could not remove the recorded Latte certificate"
        raise PublicError.new("trust_remove_failed", message)
      end
      File.delete(receipt_path)
      File.delete(snapshot)
    end

    private def certificate_path : String
      path = @proxy.root_certificate
      info = File.info?(path, follow_symlinks: false)
      unless info && StateSecurity.owned_file?(info) && (info.permissions.value & 0o022) == 0
        message = "Start Latte HTTPS services before installing certificate trust"
        raise PublicError.new("ca_unavailable", message)
      end
      path
    end

    private def fingerprint_of(certificate : String) : String
      result = @toolchain.run(:openssl, ["x509", "-outform", "DER"], input: certificate)
      unless result.success?
        message = "Latte's local certificate authority is unavailable"
        raise PublicError.new("invalid_ca", message)
      end
      Digest::SHA256.hexdigest(result.stdout)
    end

    private def default_keychain : String
      command = ["/usr/bin/security", "default-keychain", "-d", "user"]
      result = ProcessRunner.run(command, timeout: 5.seconds)
      unavailable = "The user's default keychain is unavailable"
      raise PublicError.new("keychain_unavailable", unavailable) unless result.success?
      path = result.stdout.strip
      path = path[1...-1] if path.starts_with?('"') && path.ends_with?('"')
      unless path.starts_with?('/') && File.file?(path)
        raise PublicError.new("keychain_unavailable", unavailable)
      end
      path
    end

    private def trust_directory : String
      File.join(@paths.root, "trust")
    end

    private def snapshot : String
      File.join(trust_directory, "root.crt")
    end

    private def receipt_path : String
      File.join(trust_directory, "receipt.json")
    end

    private def write_receipt(digest : String, keychain : String, state : String) : Nil
      document = {version: RECEIPT_FORMAT, sha256: digest, keychain: keychain, state: state}
      ConfigFile.write(receipt_path, document.to_json)
    end

    private def receipt : JSON::Any?
      return unless File.info?(receipt_path, follow_symlinks: false)
      StateSecurity.validate_owned_directory(trust_directory)
      info = File.info(receipt_path, follow_symlinks: false)
      unless StateSecurity.private_file?(info)
        message = "Latte certificate receipt is not a private owned file"
        raise PublicError.new("trust_receipt_invalid", message)
      end
      saved = JSON.parse(File.read(receipt_path))
      StateFormat.check!(receipt_path, saved["version"].as_i, RECEIPT_FORMAT)
      unless saved["sha256"].as_s.matches?(/\A[0-9a-f]{64}\z/)
        raise PublicError.new("trust_receipt_invalid", "Latte certificate receipt is invalid")
      end
      saved
    end
  end
end
