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

  class PacketStream
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
      @packets = PacketStream.new(input, output)
      @chunk_size = chunk_size
    end

    def run
      packets.send(:filename, filename)
      while chunk = data.read(@chunk_size)
        chunk_hash = Digest::MD5.digest(chunk)
        packets.send(:next_chunk_digest, chunk_hash)
        case packets.receive([:have_chunk, :need_chunk]).type
        when :have_chunk then next
        when :need_chunk then packets.send(:next_chunk_content, chunk)
        end
      end
      packets.send(:done)
    end

    attr_reader :data, :packets, :filename
  end

  class Receiver
    def initialize(chunk_size, input, output)
      @packets = PacketStream.new(input, output)
      @chunk_size = chunk_size
    end

    def run
      header = packets.receive(:filename)
      Tempfile.open('farsync') do |new_file|
        mode = File::CREAT|File::RDWR|File::BINARY
        File.open(File.basename(header.payload), mode) do |orig_file|
          while (received = packets.receive([:next_chunk_digest, :done])).type != :done
            new_file.write(
              if chunk = scan_ahead_for_chunk_with_digest(orig_file, received.payload)
                packets.send(:have_chunk)
                chunk
              else
                packets.send(:need_chunk)
                packets.receive(:next_chunk_content).payload
              end
            )
          end
          File.rename(new_file.path, orig_file.path)
        end
      end
    end

    attr_reader :packets, :chunk_size

    private

    def scan_ahead_for_chunk_with_digest(file, digest)
      initial_pos = file.tell
      if data = file.read(chunk_size * 100)
        each_chunk(data).with_index do |chunk, offset|
          if Digest::MD5.digest(chunk) == digest
            file.seek(initial_pos + offset + chunk_size)
            return chunk
          end
        end
      end
      file.seek(initial_pos)
      false
    end

    def each_chunk(string)
      Enumerator.new do |enum|
        (0...string.size).each do |i|
          enum << string[i..(i+chunk_size)]
        end
      end
    end
  end
end
