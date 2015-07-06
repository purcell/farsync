require 'digest/md5'
require 'tempfile'

module Farsync
  class Packet
    TYPES = [:filename, :next_chunk_digest, :next_chunk_content,
             :have_chunk, :need_chunk, :done]

    class Error < IOError; end

    attr_reader :type, :payload

    def initialize(type, payload="")
      @type = type
      @payload = payload
    end

    def code
      TYPES.index(type) || raise(ArgumentError, "unknown packet type #{type}")
    end

    def ==(other)
      self.class === other && [type, payload] == [other.type, other.payload]
    end

    def serialize
      [code, payload.size, payload].pack("cNa*")
    end

    def write_to(stream)
      stream.write(serialize)
      stream.flush
    end

    def self.read_from(stream)
      unless header = stream.read(5)
        raise Error, "unexpected end of stream"
      end
      code, size = header.unpack("cN")
      type = TYPES.at(code) || raise(Error, "invalid packet code #{code}")
      new(type, stream.read(size).unpack('a*').first)
    end
  end

  class Comms
    def initialize(input, output)
      @input = input
      @output = output
    end

    def send(*args)
      Packet.new(*args).write_to(output)
    end

    def receive(packet_types)
      Packet.read_from(input).tap do |packet|
        bad_packet(packet) unless Array(packet_types).include?(packet.type)
      end
    end

    attr_reader :input, :output

    private

    def bad_packet(packet)
      raise IOError, "unexpected packet type: #{packet.type}"
    end
  end

  class Sender
    def initialize(chunk_size, filename, data, input, output)
      @filename = filename
      @data = data
      @comms = Comms.new(input, output)
      @chunk_size = chunk_size
    end

    def run
      comms.send(:filename, filename)
      while chunk = data.read(@chunk_size)
        chunk_hash = Digest::MD5.digest(chunk)
        comms.send(:next_chunk_digest, chunk_hash)
        response = comms.receive([:have_chunk, :need_chunk])
        case response.type
        when :have_chunk then next
        when :need_chunk
          comms.send(:next_chunk_content, chunk)
        end
      end
      comms.send(:done)
    end

    attr_reader :data, :comms, :filename
  end

  class Receiver
    def initialize(chunk_size, input, output)
      @comms = Comms.new(input, output)
      @chunk_size = chunk_size
    end

    def run
      header = comms.receive(:filename)
      Tempfile.open('farsync') do |new_file|
        mode = File::CREAT|File::RDWR|File::BINARY
        File.open(File.basename(header.payload), mode) do |orig_file|
          while (received = comms.receive([:next_chunk_digest, :done])).type != :done
            if chunk = scan_ahead_for_chunk_with_digest(orig_file, received.payload)
              comms.send(:have_chunk)
              new_file.write(chunk)
            else
              comms.send(:need_chunk)
              content = comms.receive(:next_chunk_content)
              new_file.write(content.payload)
            end
          end
          File.rename(new_file.path, orig_file.path)
        end
      end
    end

    attr_reader :comms, :chunk_size

    private

    def scan_ahead_for_chunk_with_digest(file, digest)
      pos = file.tell
      chunk = file.read(chunk_size)
      if chunk && Digest::MD5.digest(chunk) == digest
        chunk
      else
        file.seek(pos) # still need the content
        false
      end
    end
  end
end
