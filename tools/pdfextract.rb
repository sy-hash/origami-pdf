#!/usr/bin/env ruby 

=begin

= Author: 
  Guillaume Delugré <guillaume/at/security-labs.org>

= Info:
  Extracts valuable data from a PDF document. Can extract:
    - decoded streams
    - JavaScript
    - file attachments

= License:
	Origami is free software: you can redistribute it and/or modify
  it under the terms of the GNU Lesser General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Origami is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU Lesser General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License
  along with Origami.  If not, see <http://www.gnu.org/licenses/>.

=end

begin
  require 'origami'
rescue LoadError
  ORIGAMIDIR = "#{File.dirname(__FILE__)}/.."
  $: << ORIGAMIDIR
  require 'origami'
end
include Origami

require 'optparse'
require 'rexml/document'

class OptParser
  BANNER = <<USAGE
Usage: #{$0} <PDF-file> [-afjms] [-d <output-directory>]
Extracts various data out of a document (streams, scripts, fonts, metadata, attachments).
Bug reports or feature requests at: http://origami-pdf.googlecode.com/

Options:
USAGE

  def self.parser(options)
    OptionParser.new do |opts|
      opts.banner = BANNER

      opts.on("-d", "--output-dir DIR", "Output directory") do |d|
        options[:output_dir] = d
      end

      opts.on("-s", "--streams", "Extracts all decoded streams") do
        options[:streams] = true
      end

      opts.on("-a", "--attachments", "Extracts file attachments") do
        options[:attachments] = true
      end

      opts.on("-f", "--fonts", "Extracts embedded font files") do
        options[:fonts] = true
      end

      opts.on("-j", "--js", "Extracts JavaScript scripts") do
        options[:javascript] = true
      end

      opts.on("-m", "--metadata", "Extracts metadata streams") do
        options[:metadata] = true
      end

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end
    end
  end

  def self.parse(args)
    options = 
    {
    }

    self.parser(options).parse!(args)

    options
  end
end

begin
  @options = OptParser.parse(ARGV)

  if ARGV.empty?
    STDERR.puts "Error: No filename was specified. #{$0} --help for details."
    exit 1
  else
    target = ARGV.shift
  end

  unless [:streams,:javascript,:attachments,:fonts,:metadata].any? {|opt| @options[opt]} 
    @options[:streams] =
    @options[:javascript] =
    @options[:fonts] =
    @options[:attachments] = true
  end

  if @options[:output_dir].nil?
    @options[:output_dir] = "#{File.basename(target, '.pdf')}.dump"
  end

  OUTPUT_DIR = @options[:output_dir]
  Dir::mkdir(OUTPUT_DIR) unless File.directory?(OUTPUT_DIR)

  params = 
  {
    :verbosity => Parser::VERBOSE_QUIET,
  }
  pdf = PDF.read(target, params)

  if @options[:streams]
    pdf.root_objects.find_all{|obj| obj.is_a?(Stream)}.each do |stream|
      stream_file = "#{OUTPUT_DIR}/stream_#{stream.reference.refno}.dmp" 
      File.open(stream_file, "w") do |fd|
        fd.write(stream.data)
      end
    end
  end

  if @options[:javascript]
    pdf.ls(/^JS$/).each do |script|
      script_file = "#{OUTPUT_DIR}/script_#{script.hash}.js"
      File.open(script_file, "w") do |fd|
        fd.write(
          case script
            when Stream then
              script.data
            else
              script.value
          end
        )
      end
    end

    # Also checking for presence of JavaScript in XML forms.
    if pdf.has_form? and pdf.Catalog.AcroForm.has_key?(:XFA)
      xfa = pdf.Catalog.AcroForm[:XFA].solve

      case xfa
        when Array then
          xml = ""
          i = 0
          xfa.each do |packet|
            if i % 2 == 1
              xml << packet.solve.data
            end

            i = i + 1
          end
        when Stream then
          xml = xfa.data
        else
          reject("Malformed XFA dictionary")
      end

      xfadoc = REXML::Document.new(xml)
      REXML::XPath.match(xfadoc, "//script").each do |script|
        script_file = "#{OUTPUT_DIR}/script_#{script.hash}.js"
        File.open(script_file, 'w') do |fd|
          fd.write(script.text)
        end
      end
    end
  end

  if @options[:attachments]
    pdf.ls_names(Names::Root::EMBEDDEDFILES).each do |name, attachment|
      attached_file = "#{OUTPUT_DIR}/attached_#{File.basename(name)}"
      spec = attachment.solve
      ef = spec[:EF].solve
      f = ef[:F].solve

      File.open(attached_file, "w") do |fd|
        fd.write(f.data)
      end
    end
  end

  if @options[:fonts]
    pdf.root_objects.find_all{|obj| obj.is_a?(Stream)}.each do |stream|
      font = stream.xrefs.find{|obj| obj.is_a?(FontDescriptor)}
      if font
        font_file = "#{OUTPUT_DIR}/font_#{File.basename(font.FontName.value.to_s)}"
        File.open(font_file, "w") do |fd|
          fd.write(stream.data)
        end
      end
    end
  end

  if @options[:metadata]
    pdf.root_objects.find_all{|obj| obj.is_a?(MetadataStream)}.each do |stream|
      metadata_file = "#{OUTPUT_DIR}/metadata_#{stream.reference.refno}.xml"
      File.open(metadata_file, "w") do |fd|
        fd.write(stream.data)
      end
    end
  end

rescue SystemExit
rescue Exception => e
  STDERR.puts "#{e.class}: #{e.message}"
  exit 1
end

