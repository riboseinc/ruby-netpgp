require 'English'
require 'forwardable'

module NetPGP

class Keyring
  extend Forwardable
  delegate [:size, :each, :select, :[], :push, :clear] => :@keys

  attr_reader :keys

  def initialize
    @keys = []
  end

  def self.load(data, armored=true, &passphrase_provider)
    kr = Keyring.new
    kr.add(data, armored, &passphrase_provider)
    kr
  end

  def add(data, armored=true, &passphrase_provider)
    keys = NetPGP::load_keys(data, armored, &passphrase_provider)
    @keys.push(*keys)
    keys.size
  end

  def verify(data, armored=true)
    NetPGP::verify(@keys, data, armored)
  end

  def export(key, armored=true)
    raise if key.parent
    is_public = key.is_a?(PublicKey)
    if is_public
      seckey = secret_keys.find {|sk| sk.key_id == key.key_id}
    else
      seckey = key
    end
    return nil if not seckey
    output_ptr = FFI::MemoryPointer.new(:pointer)
    mem_ptr = FFI::MemoryPointer.new(:pointer)
    output = nil
    mem = nil
    decrypted_seckey = nil
    begin
      LibNetPGP::pgp_setup_memory_write(output_ptr, mem_ptr, 4096)
      output = LibNetPGP::PGPOutput.new(output_ptr.read_pointer)
      mem = LibNetPGP::PGPMemory.new(mem_ptr.read_pointer)
      native_ptr = LibC::calloc(1, LibNetPGP::PGPKey.size)
      native = LibNetPGP::PGPKey.new(native_ptr)
      native_auto = FFI::AutoPointer.new(native_ptr, LibNetPGP::PGPKey.method(:release))
      key.to_native_key(native)
      decrypted_seckey = seckey.decrypted_seckey
      return nil if not decrypted_seckey
      # this is necessary for signatures
      seckey = SecretKey.from_native(decrypted_seckey)
      seckey.to_native(native[:key][:seckey])
      native[:type] = :PGP_PTAG_CT_SECRET_KEY
      if is_public
        LibNetPGP::dynarray_clear(native, 'uid', :string)
        key.userids.each {|userid|
          LibNetPGP::pgp_add_selfsigned_userid(native, userid)
        }
      end
      # PGPKeyring is a ManagedStruct
      subkeysring_ptr = LibC::calloc(1, LibNetPGP::PGPKeyring.size)
      subkeysring = LibNetPGP::PGPKeyring.new(subkeysring_ptr)
      NetPGP::keys_to_native_keyring(key.subkeys, subkeysring)
      # add a binding signature to each subkey
      (0..LibNetPGP::dynarray_count(subkeysring, 'key') - 1).each {|n|
        subkey = LibNetPGP::dynarray_get_item(subkeysring, 'key', LibNetPGP::PGPKey, n)
        LibNetPGP::dynarray_clear(subkey, 'packet', LibNetPGP::PGPSubPacket)
        NetPGP::add_subkey_signature(native, subkey)
      }
      if is_public
        ret = LibNetPGP::pgp_write_xfer_pubkey(output, native, subkeysring, armored ? 1 : 0)
      else
        decrypted_key_ptr = LibC::calloc(1, LibNetPGP::PGPKey.size)
        decrypted_key = LibNetPGP::PGPKey.new(decrypted_key_ptr)
        decrypted_key_auto = FFI::AutoPointer.new(decrypted_key_ptr, LibNetPGP::PGPKey.method(:release))
        seckey.to_native_key(decrypted_key)
        key.userids.each {|userid|
          LibNetPGP::pgp_add_selfsigned_userid(decrypted_key, userid)
        }
        decrypted_key[:key][:seckey][:s2k_usage] = :PGP_S2KU_ENCRYPTED_AND_HASHED
        decrypted_key[:key][:seckey][:alg] = :PGP_SA_CAST5
        decrypted_key[:key][:seckey][:s2k_specifier] = :PGP_S2KS_SALTED
        (0..LibNetPGP::dynarray_count(subkeysring, 'key') - 1).each {|n|
          subkey = LibNetPGP::dynarray_get_item(subkeysring, 'key', LibNetPGP::PGPKey, n)
          subkey[:key][:seckey][:s2k_usage] = :PGP_S2KU_ENCRYPTED_AND_HASHED
          subkey[:key][:seckey][:alg] = :PGP_SA_CAST5
          subkey[:key][:seckey][:s2k_specifier] = :PGP_S2KS_SALTED
        }
        ret = LibNetPGP::pgp_write_xfer_seckey(output, decrypted_key, key.passphrase, key.passphrase.size, subkeysring, armored ? 1 : 0)
      end
      return nil if ret != 1
      data = mem[:buf].read_bytes(mem[:length])
      data
    ensure
      LibNetPGP::pgp_teardown_memory_write(output, mem) if mem
      LibNetPGP::pgp_seckey_free(decrypted_seckey) if decrypted_seckey
    end
  end

  def public_keys
    self.select {|key|
      key.is_a?(PublicKey)
    }
  end

  def secret_keys
    self.select {|key|
      key.is_a?(SecretKey)
    }
  end

  def to_native(native)
    keys_to_native_keyring(@keys, native)
  end

end

PARSE_KEYRING = Proc.new do |state, passphrase_provider, pkt, data|
  next :PGP_RELEASE_MEMORY if state[:errors].any?

  begin
    lastkey = state[:keys].last
    case pkt[:tag]
    when :PGP_PTAG_CT_PUBLIC_KEY
      key = PublicKey::from_native(pkt[:u][:pubkey])
      state[:keys].push(key)
    when :PGP_PTAG_CT_PUBLIC_SUBKEY
      key = PublicKey::from_native(pkt[:u][:pubkey])
      lastkey.add_subkey(key)
      state[:keys].push(key)
    when :PGP_PTAG_CT_ENCRYPTED_SECRET_KEY
      key = SecretKey::from_native(pkt[:u][:seckey], true)
      state[:keys].push(key)
    when :PGP_PTAG_CT_ENCRYPTED_SECRET_SUBKEY
      key = SecretKey::from_native(pkt[:u][:seckey], true)
      lastkey.add_subkey(key)
      state[:keys].push(key)
    when :PGP_PTAG_CT_SECRET_KEY
      key = SecretKey::from_native(pkt[:u][:seckey])
      if state[:passphrase]
        key.passphrase = state[:passphrase]
        state[:passphrase] = nil
      end
      state[:keys].push(key)
    when :PGP_PTAG_CT_SECRET_SUBKEY
      key = SecretKey::from_native(pkt[:u][:seckey])
      lastkey.add_subkey(key)
      state[:keys].push(key)
    when :PGP_GET_PASSPHRASE
      seckey_ptr = pkt[:u][:skey_passphrase][:seckey]
      seckey = LibNetPGP::PGPSecKey.new(seckey_ptr)
      key = SecretKey::from_native(seckey)
      passphrase = passphrase_provider.call(key)
      if passphrase and passphrase != ''
        passphrase_mem = LibC::calloc(1, passphrase.bytesize + 1)
        passphrase_mem.write_bytes(passphrase)
        pkt[:u][:skey_passphrase][:passphrase].write_pointer(passphrase_mem)
        state[:passphrase] = passphrase
        next :PGP_KEEP_MEMORY
      end
    when :PGP_PARSER_PACKET_END
      if lastkey.is_a? NetPGP::SecretKey
        raw_packet = pkt[:u][:packet]
        bytes = raw_packet[:raw].read_bytes(raw_packet[:length])
        lastkey.raw_subpackets.push(bytes)
      end
    when :PGP_PTAG_CT_USER_ID
      lastkey.userids.push(pkt[:u][:userid].force_encoding('utf-8'))
    when :PGP_PTAG_SS_KEY_EXPIRY
      lastkey.expiration_time = lastkey.creation_time + pkt[:u][:ss_time]
    else
      # For debugging
      #puts "Unhandled tag: #{pkt[:tag]}"
    end # case
  rescue
    state[:errors].push($ERROR_INFO)
  end
  next :PGP_RELEASE_MEMORY
end

DEFAULT_PASSPHRASE_PROVIDER = Proc.new do |seckey|
  nil
end

def self.load_keys(data, armored=true, &passphrase_provider)
  # Just for readability
  print_errors = 0
  stream_mem = LibC::calloc(1, LibNetPGP::PGPStream.size)
  # This will free the above memory (PGPStream is a ManagedStruct)
  stream = LibNetPGP::PGPStream.new(stream_mem)
  stream[:readinfo][:accumulate] = 1
  LibNetPGP::pgp_parse_options(stream, :PGP_PTAG_SS_ALL, :PGP_PARSE_PARSED)

  # This memory will be GC'd
  mem = FFI::MemoryPointer.new(:uint8, data.bytesize)
  mem.write_bytes(data)

  LibNetPGP::pgp_reader_set_memory(stream, mem, mem.size)
  state = {keys: [], errors: []}
  provider = block_given? ? passphrase_provider : DEFAULT_PASSPHRASE_PROVIDER
  callback = NetPGP::PARSE_KEYRING.curry[state][provider]
  LibNetPGP::pgp_set_callback(stream, callback, nil)
  LibNetPGP::pgp_reader_push_dearmour(stream) if armored
  if LibNetPGP::pgp_parse(stream, print_errors) != 1
    state[:errors].push('pgp_parse failed')
  end
  LibNetPGP::pgp_reader_pop_dearmour(stream) if armored

  errors = stream_errors(stream)
  state[:errors].push(errors) if errors.any?

  raise state[:errors].join("\n") if state[:errors].any?
  state[:keys]
end

def self.keys_to_native_keyring(keys, native)
  raise if not native[:keys].null?

  for key in keys
    native_key = LibNetPGP::PGPKey.new
    key.to_native_key(native_key)
    LibNetPGP::dynarray_append_item(native, 'key', LibNetPGP::PGPKey, native_key)
  end
end

def self.verify(keys, data, armored=true)
  native_keyring_ptr = LibC::calloc(1, LibNetPGP::PGPKeyring.size)
  native_keyring = LibNetPGP::PGPKeyring.new(native_keyring_ptr)
  NetPGP::keys_to_native_keyring(keys, native_keyring)

  pgpio = LibNetPGP::PGPIO.new
  pgpio[:outs] = LibC::fdopen($stdout.to_i, 'w')
  pgpio[:errs] = LibC::fdopen($stderr.to_i, 'w')
  pgpio[:res] = pgpio[:errs]

  data_buf = FFI::MemoryPointer.new(:uint8, data.bytesize)
  data_buf.write_bytes(data)

  # pgp_validate_mem frees this
  mem_ptr = LibC::calloc(1, LibNetPGP::PGPMemory.size)
  mem = LibNetPGP::PGPMemory.new(mem_ptr)
  LibNetPGP::pgp_memory_add(mem, data_buf, data_buf.size)

  # ManagedStruct, this frees itself
  result_ptr = LibC::calloc(1, LibNetPGP::PGPValidation.size)
  result = LibNetPGP::PGPValidation.new(result_ptr)

  ret = LibNetPGP::pgp_validate_mem(pgpio, result, mem, nil, armored ? 1 : 0, native_keyring)
  ret == 1
end

end # module NetPGP

