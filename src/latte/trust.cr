require "./toolchain"
require "./proxy"
require "./server"
require "digest/sha256"

module Caramel::Latte
  # Trust is a per-user operation. The privileged port/DNS installer never
  # receives CA private keys and never modifies the system trust store.
  class Trust
    def initialize(@paths : Paths, @proxy : Proxy, @toolchain : Toolchain = Toolchain.for_checkout)
    end

    def fingerprint : String
      fingerprint_of(File.read(certificate_path))
    end

    def install : Nil
      certificate = File.read(certificate_path)
      digest = fingerprint_of(certificate)
      saved = receipt
      if saved && saved["sha256"].as_s != digest
        raise PublicError.new("ca_changed", "Remove the previously installed Latte certificate before rotating its authority")
      end
      keychain = saved ? saved["keychain"].as_s : default_keychain
      # Record a public certificate snapshot before installation, making
      # interrupted installation and later removal refer to the same CA.
      ConfigFile.directory(trust_directory)
      ConfigFile.write(snapshot, certificate)
      ConfigFile.write(receipt_path, {version: 1, sha256: digest, keychain: keychain, state: "pending"}.to_json)
      result = ProcessRunner.run(["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, snapshot], timeout: 60.seconds)
      unless result.success?
        raise PublicError.new("trust_failed", "macOS did not install the local certificate trust; retry Latte HTTPS setup")
      end
      ConfigFile.write(receipt_path, {version: 1, sha256: digest, keychain: keychain, state: "installed"}.to_json)
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
      result = ProcessRunner.run(["/usr/bin/security", "delete-certificate", "-t", "-Z", saved["sha256"].as_s.upcase, keychain], timeout: 60.seconds)
      raise PublicError.new("trust_remove_failed", "macOS could not remove the recorded Latte certificate") unless result.success?
      File.delete(receipt_path)
      File.delete(snapshot)
    end

    private def certificate_path : String
      path = @proxy.root_certificate
      info = File.info?(path, follow_symlinks: false)
      unless info && info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && (info.permissions.value & 0o022) == 0
        raise PublicError.new("ca_unavailable", "Start Latte HTTPS services before installing certificate trust")
      end
      path
    end

    private def fingerprint_of(certificate : String) : String
      result = @toolchain.run(:openssl, ["x509", "-outform", "DER"], input: certificate)
      raise PublicError.new("invalid_ca", "Latte's local certificate authority is unavailable") unless result.success?
      Digest::SHA256.hexdigest(result.stdout)
    end

    private def default_keychain : String
      result = ProcessRunner.run(["/usr/bin/security", "default-keychain", "-d", "user"], timeout: 5.seconds)
      raise PublicError.new("keychain_unavailable", "The user's default keychain is unavailable") unless result.success?
      path = result.stdout.strip
      path = path[1...-1] if path.starts_with?('"') && path.ends_with?('"')
      unless path.starts_with?('/') && File.file?(path)
        raise PublicError.new("keychain_unavailable", "The user's default keychain is unavailable")
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

    private def receipt : JSON::Any?
      return nil unless File.info?(receipt_path, follow_symlinks: false)
      StateSecurity.validate_owned_directory(trust_directory)
      info = File.info(receipt_path, follow_symlinks: false)
      unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
        raise PublicError.new("trust_receipt_invalid", "Latte certificate receipt is not a private owned file")
      end
      saved = JSON.parse(File.read(receipt_path))
      unless saved["version"].as_i == 1 && saved["sha256"].as_s.matches?(/\A[0-9a-f]{64}\z/)
        raise PublicError.new("trust_receipt_invalid", "Latte certificate receipt is invalid")
      end
      saved
    end
  end
end
