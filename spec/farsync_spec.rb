require 'farsync'
require 'stringio'

def packet(*args)
  Farsync::Packet.new(*args)
end

RSpec.describe Farsync::Packet do

  describe "packet serialisation" do
    it "can read/write reversibly to a stream" do
      stream = StringIO.new
      p = Farsync::Packet.new(:next_chunk_digest, "just a test")
      p.write_to(stream)
      stream.rewind
      p2 = Farsync::Packet.read_from(stream)
      expect(p).to eq(p2)
    end

    it "raises error when unserializing from an empty stream" do
      stream = StringIO.new
      expect { Farsync::Packet.read_from(stream) }.to raise_error(Farsync::Packet::Error)
    end
  end

end

RSpec.describe Farsync::Sender do

  let(:chunk_size) { 100 }
  let(:data) { "here is my data" }
  let(:filename) { "some filename" }
  let(:input) { double("input") }
  let(:output) { double("output") }
  subject(:sender) { Farsync::Sender.new(chunk_size, filename, StringIO.new(data), input, output)}

  def expect_send(*args)
    expect(output).to receive(:write).with(packet(*args).serialize).ordered
    expect(output).to receive(:flush).ordered
  end

  def expect_reply(*args)
    expect(Farsync::Packet).to receive(:read_from).with(input).and_return(packet(*args)).ordered
  end

  before do
    expect_send(:filename, filename)
  end

  context "when sending digests for the next chunk" do
    it "skips the chunk if the receiver has it" do
      expect_send(:next_chunk_digest, Digest::MD5.digest(data))
      expect_reply(:have_chunk, "")
      expect_send(:done, "")
      sender.run
    end

    it "sends the chunk if the receiver wants it" do
      expect_send(:next_chunk_digest, Digest::MD5.digest(data))
      expect_reply(:need_chunk, "")
      expect_send(:next_chunk_content, data)
      expect_send(:done, "")
      sender.run
    end
  end
end

RSpec.describe Farsync::Receiver do

  let(:chunk_size) { 100 }
  let(:local_data) { "here is my local data" }
  let(:filename) { "some filename" }
  let(:input) { double("input") }
  let(:output) { double("output") }
  let(:local_file) {
    StringIO.new(local_data, 'r').tap do |f|
      allow(f).to receive(:path).and_return(filename)
    end
  }
  let(:temp_file) {
    StringIO.new('', 'w').tap do |f|
      allow(f).to receive(:path).and_return("temp file path")
    end
  }
  subject(:receiver) { Farsync::Receiver.new(chunk_size, input, output)}

  def expect_receive(*args)
    expect(Farsync::Packet).to receive(:read_from).with(input).and_return(packet(*args)).ordered
  end

  def expect_send(*args)
    expect(output).to receive(:write).with(packet(*args).serialize).ordered
    expect(output).to receive(:flush).ordered
  end

  before do
    expect_receive(:filename, filename)
    expect(File).to receive(:open).with(filename, File::CREAT|File::RDWR|File::BINARY).and_yield(local_file)
    expect(Tempfile).to receive(:open).and_yield(temp_file)
  end

  context "when receiving digests for the next chunk" do
    it "skips the chunk if the receiver has it" do
      expect_receive(:next_chunk_digest, Digest::MD5.digest(local_data))
      expect_send(:have_chunk, "")
      expect_receive(:done, "")
      expect(File).to receive(:rename).with(temp_file.path, local_file.path)
      receiver.run
    end

    it "requests the chunk if we don't have it" do
      remote_data = "here is some different data"
      expect_receive(:next_chunk_digest, Digest::MD5.digest(remote_data))
      expect_send(:need_chunk, "")
      expect_receive(:next_chunk_content, remote_data)
      expect_receive(:done, "")
      expect(File).to receive(:rename).with(temp_file.path, local_file.path)
      receiver.run
      expect(temp_file.string).to eq(remote_data)
    end
  end
end
