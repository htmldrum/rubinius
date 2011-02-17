# All the tasks to manage building the Rubinius kernel--which is essentially
# the Ruby core library plus Rubinius-specific files. The kernel bootstraps
# a Ruby environment to the point that user code can be loaded and executed.
#
# The basic rule is that any generated file should be specified as a file
# task, not hidden inside some arbitrary task. Generated files are created by
# rule (e.g. the rule for compiling a .rb file into a .rbc file) or by a block
# attached to the file task for that particular file.
#
# The only tasks should be those names needed by the user to invoke specific
# parts of the build (including the top-level build task for generating the
# entire kernel).

# drake does not allow invoke to be called inside tasks
def kernel_clean
  rm_f Dir["**/*.rbc",
           "**/.*.rbc",
           "kernel/**/signature.rb",
           "spec/capi/ext/*.{o,sig,#{$dlext}}",
           "runtime/**/load_order.txt",
           "runtime/platform.conf"],
    :verbose => $verbose
end

require 'kernel/bootstrap/iseq.rb'

# So that the compiler can try and use the config
module Rubinius
  Config = { 'eval.cache' => false }

  class Channel
    def receive
    end

    def <<(val)
    end

    def as_lock
      yield
    end
  end unless const_defined?(:Channel)
end

# The rule for compiling all kernel Ruby files
rule ".rbc" do |t|
  source = t.prerequisites.first
  puts "RBC #{source}"
  Rubinius::Compiler.compile source, t.name, 1, [:default, :kernel]
end

# Collection of all files in the kernel runtime. Modified by
# various tasks below.
runtime = FileList["runtime/platform.conf"]

# Names of subdirectories of the runtime/ directory.
dir_names = [
  "bootstrap",
  "platform",
  "common",
  "delta"
]

dir_names.each do |dir|
  directory(runtime_dir = "runtime/#{dir}")
  runtime << runtime_dir

  load_order = "runtime/#{dir}/load_order.txt"
  runtime << load_order

  file load_order => "kernel/#{dir}/load_order.txt" do |t|
    cp t.prerequisites.first, t.name, :verbose => $verbose
  end
end

# Generate file tasks for all kernel files.
compiler_signature = "kernel/signature.rb"

FileList[
  "kernel/**/*.rb",
  compiler_signature
].each do |rb|
  rbc = rb.sub(/^kernel/, "runtime") + "c"

  file rbc => [rb, compiler_signature]
  runtime << rbc
end

# Directories to store the core library runtime files (.rbc's)
runtime_index = "runtime/index"

file runtime_index do |t|
  File.open t.name, "w" do |file|
    file.puts dir_names
  end
end

# Compile all compiler files during build stage
opcodes = "lib/compiler/opcodes.rb"

compiler_files = FileList[
  "lib/compiler.rb",
  "lib/compiler/**/*.rb",
  opcodes,
  "lib/compiler/generator_methods.rb",
  "lib/melbourne.rb",
  "lib/melbourne/**/*.rb"
]

compiler_files.each do |rb|
  rbc = rb + "c"

  file rbc => [rb, compiler_signature]
  runtime << rbc
end

parser_ext_files = FileList[
  "lib/ext/melbourne/**/*.{c,h}pp",
  "lib/ext/melbourne/grammar.y",
  "lib/ext/melbourne/lex.c.tab"
]

# Generate a sha1 of all parser and compiler files to use as
# as signature in the .rbc files.
file compiler_signature => compiler_files + parser_ext_files do |t|
  require 'digest/sha1'
  digest = Digest::SHA1.new

  t.prerequisites.each do |name|
    File.open name, "r" do |file|
      while chunk = file.read(1024)
        digest << chunk
      end
    end
  end

  # Collapse the digest to a 64bit quantity
  hd = digest.hexdigest
  hash = hd[0, 16].to_i(16) ^ hd[16,16].to_i(16) ^ hd[32,8].to_i(16)

  File.open t.name, "wb" do |file|
    file.puts "# This file is generated by rakelib/kernel.rake. The signature"
    file.puts "# is used to ensure that only current .rbc files are loaded."
    file.puts "#"
    file.puts "Rubinius::Signature = #{hash}"
  end

  File.open "runtime/signature", "wb" do |file|
    file.puts hash
  end
end

namespace :compiler do
  if BUILD_CONFIG[:which_ruby] == :ruby
    melbourne = "lib/ext/melbourne/ruby/melbourne.#{$dlext}"

    file melbourne => "extensions:melbourne_mri"

    task :load => [compiler_signature, melbourne] + compiler_files do
      require File.expand_path("../../lib/compiler", __FILE__)
      require File.expand_path("../../kernel/signature", __FILE__)
    end
  else
    task :load => compiler_signature do
      require File.expand_path("../../kernel/signature", __FILE__)
    end
  end
end

desc "Build all kernel files (alias for kernel:build)"
task :kernel => 'kernel:build'

namespace :kernel do
  desc "Build all kernel files"
  task :build => ['compiler:load', runtime_index] + runtime

  desc "Delete all .rbc files"
  task :clean do
    kernel_clean
  end
end
