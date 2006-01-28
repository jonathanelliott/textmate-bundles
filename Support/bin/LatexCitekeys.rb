#!/usr/bin/env ruby -s
#   LatexCitekeys.rb
#   Author: Charilaos Skiadas
#
# Checks whether files passed as arguments are bib files, and for those searches all cite keys and 
# returns them as list of options, optionally filtered by a word.
#
# If the files are tex files, looks for any \bibliography entries in them, and uses those bibfiles
#
# Shell option -p=phrase allows the search for the phrase p. It is stored in variable $p.
#
#################################
#  Helper functions for parsing the bib files

# To be used with a block. Sends to the block hash tables with entries: citekey author and title.
# File is supposed to be a string with the contents of the bibfile
def parsefile(file)
  info = Hash.new
  array = file.split("\n")
  line = ""
  until (array.empty? || line.match(/@[^{]*\{([^, ]*),/)) do
    line = array.shift
  end
  until (array.empty?) do
    info["citekey"] = $1
    line = array.shift.strip
    until (array.empty? || line.match(/@[^{]*\{([^, ]*),/)) do
      if line.match(/(Editor|Author|Title) *= *\{(.*)\},$/i) then
        m1, m2 = $1, $2
        info[m1.downcase.sub("editor","author")] = m2
      end
      line = array.shift.strip
    end
    yield info
    info.clear
  end
  return
end

#Returns a list of files with extension fileExt recursively searching in the files in 
# initialList for \include{} or \bibliography{}, removing duplicates. If given a block, runs 
# it on them. Uses kpsewhich to find paths of interest not derived from each file.
def recursiveFileSearch(initialList,fileExt)
  extraPathList = `kpsewhich -show-path=#{fileExt}`.split(/:!!|:/)
  extraPathList.unshift("")
  case fileExt 
    when "bib" then regexp = /\\bibliography\{([^}]*)\}/
    when "tex" then regexp = /\\(?:include|input)\{([^}]*)\}/
    else return
  end
  visitedFilesList = Hash.new
  tempFileList = initialList.clone
  listToReturn = Array.new
  until (tempFileList.empty?) 
    filename = tempFileList.shift
    # Have we visited this file already?
    unless visitedFilesList.has_key?(filename) then
      visitedFilesList[filename] = filename
      # First, find file's path.
      filepath = File.dirname(filename) + "/"
      File.open(filename) do |file|
        file.each do |line|
          # search for links
          if line.match(regexp) then
            m = $1
            # Need to deal with the case of multiple words here, separated by comma.
            list = m.split(',')
            list.each do |item|
              # need to look at all paths in extraPathList for the file
              (extraPathList << filepath).each do |path|
                testFilePath = path + if (item.strip.slice(-4,4) != ".#{fileExt}") then item + ".#{fileExt}" else item end
                if File.exist?(testFilePath) then
                  listToReturn << testFilePath
                  if (fileExt == "tex") then tempFileList << testFilePath end
                  if block_given? then 
                    File.open(testFilePath) {|file| yield file}
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return listToReturn
end


##############################
#### Actual program
#
#
# First, create list of files to be processed
initialFileList = Array.new
ARGV.each {|filename| 
  if File.exist?(filename) then
     initialFileList << filename 
  end}
bibFileList = Array.new
texFileList = Array.new
initialFileList.each do |filename|
  if File.exist?(filename) then
    if (filename.match(/\.bib$/)) then
      # It's a bib file! Pass it into the list for further work.
      bibFileList << filename
    else
      # It's a tex file! pass it to the texFileList
      texFileList << filename
    end
  end
end
### Create list of bib files by recursively traversing texfiles and files \included in them.
texFileList += recursiveFileSearch(texFileList,"tex")
completionsList = Array.new
recursiveFileSearch(texFileList.uniq,"bib") { |file|
  parsefile(file.read) do |info|
    if ($full.nil?) then
      if ($p.nil? || (info["citekey"]).index($p) == 0) then
        # This is the case when it's used from the inline completion command. 
        # Just searches for phrase in beginning of citekey.
        # NOTE: The case must also match.
        completionsList << info["citekey"]
      end
    elsif ($p.nil? || ((info["citekey"] + info["author"]) + info["title"]).downcase.match($p.downcase)) then
      # Case where we return the titles and authors as well.
      # Results are in the form "citekey % author % title".
      citekey = info["citekey"]
      author = info["author"].gsub(/\\\'|\'/,'')
      title = info["title"].gsub(/\\\'|\'/,'')
      completionsList << ("'#{citekey} \% #{author} \% #{title}'")
    end
  end
}
print completionsList.uniq.sort.join(", ")