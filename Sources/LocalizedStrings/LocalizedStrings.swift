// Ported to Swift by Ben Kennedy on 2018-Mar-02, based on my original Perl version of 2013-Oct-09.
// Copyright 2013 Kashoo Cloud Accounting Inc. Copyright 2018 Kashoo Systems Inc.

// This is a build-time utility that accumulates all localizable .strings files and verifies their mutual consistency.
// Inspired by Chris Luft's initial localization-checking Python script of Sept 2013.
//
// Usage: invoke with source root directory as argument.
//
// A verbose summary of findings will be output. If any strings are found to be missing, or present but unused, exit code will be non-zero.
//
// Theory of operation:
// - Complete localizations are expected for ALL languages for which at least one *.lproj bundle exists somewhere in the project.
// (Some sub-paths will be skipped, e.g. for Cocoapods and build directory, as configured below.)
// - Each localizable set ("strings table", in NSLocalizedString parlance) will be assessed for all expected languages.
// - The base language, as configured below (e.g. "en"), will be regarded as the required set for each strings table.
//
// Notes:
// - Any strings present in the base language, but missing from another language, will be reported.
// - Any strings not present in the base language, but present in another language, will also be reported.
// - Differing file encodings amongst .strings files (e.g. utf-8 vs. utf-16) are handled as best as possible.
//
// If there are any issues worth reporting, the script exits with status code 3.
// (This lets the caller distinguish between a successful but failing check, vs. any other fatal error.)

import Foundation
import Utility

class LocalizedStrings {
    
    var baseLang = "en"
    var searchRoot: String!
    var excludePaths: [String]!
    var verbose = false
    
    func main() {
        do {
            let nominalExcludePaths = "$BUILT_PRODUCTS_DIR and $PODS_ROOT"
            
            let parser = ArgumentParser(usage: "[--baselang lang] [--exclude path1 [path2 ...]] [-v|--verbose] <searchRoot>", overview: "A build-time utility that accumulates all localizable .strings files and verifies their mutual consistency.")
            let baseLangOpt = parser.add(option: "--baselang", shortName: nil, kind: String.self, usage: "Base language to use as the canonical reference for required strings. (Default is \"\(baseLang)\".)")
            let searchRootOpt = parser.add(positional: "searchRoot", kind: String.self, optional: false, usage: "The directory to scour recursively for .strings files.", completion: .filename)
            let excludeOpt = parser.add(option: "--exclude", shortName: nil, kind: [String].self, strategy: .upToNextOption, usage: "Additional directory path(s) to exclude from the search. (Default includes \(nominalExcludePaths).)", completion: .filename)
            let verboseOpt = parser.add(option: "--verbose", shortName: "-v", kind: Bool.self, usage: "Verbose mode.")
            
            let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
            let parsedArguments = try parser.parse(arguments)
            
            baseLang = parsedArguments.get(baseLangOpt) ?? baseLang
            searchRoot = parsedArguments.get(searchRootOpt)
            verbose = parsedArguments.get(verboseOpt) ?? verbose
            
            excludePaths = defaultExcludePaths()
            if let paths = parsedArguments.get(excludeOpt) {
                excludePaths.append(contentsOf: paths)
            }
            
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: searchRoot, isDirectory: &isDir),
                isDir.boolValue == true else {
                    die("Search root \(searchRoot) is not a directory.")
            }
            
            if verbose {
                log("Search root: " + searchRoot)
                log("Excluded paths: " + excludePaths.joined(separator: ", "))
                log("Base language: " + baseLang)
            }
            
            try original()
            
        } catch let error as ArgumentParserError {
            die(error.description)
        } catch {
            die(error.localizedDescription)
        }
    }
    
    /// Prepare some path exclusions for locations we do not want to search.
    ///
    func defaultExcludePaths() -> [String] {
        var excludePaths: [String] = []
        
        func warnMissingEnv(_ env: String) {
            log("$\(env) is not set in the environment. Are you sure Xcode invoked this script?")
        }
        
        // Exclude the CocoaPods directory.
        if let podsRoot = ProcessInfo().environment["PODS_ROOT"] {
            excludePaths.append(podsRoot)
        } else {
            warnMissingEnv("PODS_ROOT")
        }
        
        // Xcode does not expose an env var that describes the workspace's base build products path; all of them refer to
        // target-specific directories thereunder. Hence, for proper exclusion, we must manually determine the nexus.
        if let builtProductsDir = ProcessInfo().environment["BUILT_PRODUCTS_DIR"] {
            // First, determine whether the build products dir is in fact subordinate to the search path.
            let commonComponents = commonPathComponents(searchRoot, builtProductsDir)
            if commonComponents.count > 0 {
                // Strip off everything but the first directory beneath the search path.
                // (e.g. searchPath/build/Kashoo/Build/Products/Development-iphonesimulator -> searchPath/build)
                let buildComponents = (builtProductsDir as NSString).pathComponents.prefix(commonComponents.count + 1)
                let path = NSURL.fileURL(withPathComponents: Array(buildComponents))!.path
                excludePaths.append(path)
            }
        } else {
            warnMissingEnv("BUILT_PRODUCTS_DIR")
        }
        
        return excludePaths
    }
    
    func original() throws {
        
        // Generate a list of pathnames to all .strings files.
        var findArguments = [searchRoot!, "-name", "*.strings"]
        for path in excludePaths {
            for arg in ["-not", "-path", "\(path)/*"] {
                findArguments.append(arg)
            }
        }
        let allStringsPaths = try process(command: "/usr/bin/find", arguments: findArguments).split(separator: "\n")
        
        var langSet = Set<String>()
        var pseudoPaths: [String: (String, String)] = [:]
        
        // Decompose the strings pathnames into canonical localizable bundle names and languages.
        for strpath in allStringsPaths {
            // Parse these paths into parts.
            if let strings = regex_match("^(.+)/(.+)\\.lproj/(.+\\.strings)$", in: String(strpath)) {
                let bundlePath = strings[1]
                let lang = strings[2]
                let filename = strings[3]
                let pseudoPath = bundlePath + "/*.lproj/" + filename
                
                langSet.insert(lang)
                pseudoPaths[pseudoPath] = (bundlePath, filename)
                
                if verbose {
                    log("Found strings (\(lang)): \(strpath)")
                }
            }
        }
        
        guard langSet.contains(baseLang) else {
            die("No strings file in the base language (\(baseLang)) was found!")
        }

        // Sort the language list into an array alphabetically with the base language at the top.
        langSet.remove(baseLang)
        var langs = langSet.sorted()
        langs.insert(baseLang, at: 0)
        
        print("Assessing localizations for \(langs.count) languages (\(langs.joined(separator: ", "))) in \(pseudoPaths.count) strings tables...\n")
        
        // Initialize some statistical counters.
        var missingFileCount = 0
        var missingStringCount = 0
        var unusedStringCount = 0
        var goodStringsPaths: [String] = []
        var problemSummary = ""
        
        for pseudoPath in pseudoPaths.keys.sorted() {
            var baseStrings: [String: String]!
            let (bundlePath, filename) = pseudoPaths[pseudoPath]!
            
            for lang in langs {
                var strings: [String: String] = [:]
                var missingStrings: [String] = []
                var unusedStrings: [String] = []
                var fileEncodingName: String?
                
                let stringsPath = bundlePath + "/" + lang + ".lproj/" + filename
                
                if FileManager.default.fileExists(atPath: stringsPath) {
                    var encoding = String.Encoding.ascii // must provide a default
                    let fileStrings = try String(contentsOfFile: stringsPath, usedEncoding: &encoding).split(separator: "\n")
                    fileEncodingName = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)) as String
                    
                    for substring in fileStrings {
                        // Delete any C-style comment on the line.
                        let string = regex_replace("\\/\\*.+\\*\\/", in: String(substring), with: "")
                        
                        // Parse out the "key" = "value" pair.
                        // To support backslash-escaped internal quotation marks, this more obscure expression would work: /(["\'])(.*?(?<!\\)(\\\\)*)\1\s*=\s*"(.+)"\s*;\s*$/
                        // However, in the interests of clarity and simplicity, we will assume that keys will never contain them.
                        if let parts = regex_match("\"([^\"]+)\"\\s*=\\s*\"(.+)\"\\s*;\\s*$", in: string) {
                            let stringKey = parts[1]
                            let stringVal = parts[2]
                            strings[stringKey] = stringVal
                        }
                    }
                } else {
                    missingFileCount += 1
                }
                
                // The base language is always first; save its list as the reference.
                if lang == baseLang {
                    baseStrings = strings
                } else {
                    // Iterate all strings in the base language and bark on any that are missing.
                    for string in baseStrings.keys.sorted() {
                        if strings[string] == nil {
                            missingStrings.append(string)
                        }
                        strings[string] = nil
                    }
                    
                    // Retain all strings still remaining in the localization that are spurious.
                    unusedStrings = strings.keys.sorted()
                }
                
                if missingStrings.count + unusedStrings.count > 0 {
                    if let fileEncoding = fileEncodingName {
                        problemSummary += "\(stringsPath) (\(fileEncoding)) has "
                            + (!missingStrings.isEmpty ? "\(missingStrings.count) missing" : "")
                            + (!missingStrings.isEmpty && !unusedStrings.isEmpty ? " and " : "")
                            + (!unusedStrings.isEmpty ? "\(unusedStrings.count) unused" : "")
                            + (missingStrings.count + unusedStrings.count > 1 ? " strings" : " string")
                            + ":\n"
                    } else {
                        problemSummary += "\(stringsPath) is missing altogether (failed to open file); expecting \(missingStrings.count) strings:\n"
                    }
                    
                    for string in missingStrings {
                        problemSummary += "\tMissing: \"\(string)\" (\(baseLang): \"\(baseStrings[string]!)\")\n"
                    }
                    
                    for string in unusedStrings {
                        problemSummary += "\tExtra (not used): \"\(string)\"\n"
                    }
                    
                    missingStringCount += missingStrings.count
                    unusedStringCount += unusedStrings.count
                    
                } else {
                    // Store this filename, which we will report en masse at end.
                    goodStringsPaths.append("\(stringsPath) (\(fileEncodingName!))")
                }
            }
        }
        
        // Print output and exit.
        if !goodStringsPaths.isEmpty {
            print("\(goodStringsPaths.count) of \(allStringsPaths.count) strings files appear to be consistent:")
            for path in goodStringsPaths {
                print("\(path) is good.")
            }
        }
        
        print(problemSummary)
        
        if missingStringCount > 0 || unusedStringCount > 0 {
            let adjective = (missingStringCount > 0 ? "incomplete" : "inconsistent")
            var s = "Localization is \(adjective)! "
            
            if missingFileCount > 0 {
                s += "\(missingFileCount) \(missingFileCount == 1 ? "file" : "files")"
            }
            if missingFileCount > 0 && missingStringCount > 0 {
                s += " and "
            }
            if missingStringCount > 0 {
                s += "\(missingStringCount) \(missingStringCount == 1 ? "string" : "strings")"
            }
            if missingFileCount > 0 || missingStringCount > 0 {
                s += (missingStringCount > 0 ? " are missing" : " is missing")
            }
            if missingStringCount > 0 && unusedStringCount > 0 {
                s += "; "
            }
            if unusedStringCount > 0 {
                s += "\(unusedStringCount) \(unusedStringCount == 1 ? "string is" : "strings are") unused"
            }
            s += ".\n"
            
            print(s)
            die("warning: \(s)", rc: 3) // GCC-compliant output to stderr allows Xcode to catch and display the warning. Code 3 indicates string mismatch.
            
        } else {
            print("Localization looks good.")
            exit(0)
        }
    }
    
    // MARK: - Utilities
    
    /// Handle a fatal error by printing a message to standard error and terminating.
    ///
    /// - parameter message: A message to be printed to stderr.
    /// - parameter rc: Return code to exit with (default is `1`).
    ///
    func die(_ message: String,
             rc: Int32 = 1) -> Never {
        log(message)
        exit(rc)
    }
    
    /// Log a message to standard error.
    ///
    /// - parameter message: A message to be printed to stderr.
    ///
    func log(_ message: String) {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    }
    
    /// Return common path prefix shared by all operands.
    ///
    func commonPathComponents(_ string1: String, _ string2: String) -> [String] {
        var path1 = (string1 as NSString).pathComponents.makeIterator()
        var path2 = (string2 as NSString).pathComponents.makeIterator()
        var components: [String] = []
        
        while let p1 = path1.next(),
            let p2 = path2.next() {
                if p1 == p2 {
                    components.append(p1)
                }
        }
        
        return components
    }
    
    /// Execute an external process and return the output.
    ///
    /// - parameter command: The command to execute.
    /// - parameter arguments: Arguments to pass to the command.
    /// - returns: The standard output from the process.
    ///
    func process(command: String,
                 arguments: [String]) throws -> String {
        guard #available(macOS 10.13, *) else {
            die("We require 10.13 API on Process")
        }
        
        let process = Process()
        process.launchPath = command
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)!
    }
    
    /// Perform a regular expression match on a string.
    ///
    /// - parameter regexString: A regular expression.
    /// - parameter string: A string to parse using the regular expression.
    /// - returns: An array of matches (if any). The root match will be element zero, with any capture groups following.
    ///
    func regex_match(_ regexString: String,
                     in string: String) -> [String]?
    {
        let regex = try! NSRegularExpression(pattern: regexString, options: [])
        let matchResults = regex.matches(in: string,
                                         options: [],
                                         range: NSRange(location: 0, length: string.count))
        guard let matchResult = matchResults.first else {
            return nil
        }
        
        var strings: [String] = []
        for i in 0 ..< matchResult.numberOfRanges {
            let substring = string[Range(matchResult.range(at: i), in: string)!]
            strings.append(String(substring))
        }
        
        return strings
    }
    
    /// Perform a regular expression replacement on a string.
    ///
    /// - parameter regexString: A regular expression.
    /// - parameter source: A string to match using the regular expression.
    /// - parameter replacement: A string with which to substitute the matched source.
    /// - returns: A modified version of `source` containing `replacement` according to the `regexString`.
    ///
    func regex_replace(_ regexString: String,
                       in source: String,
                       with replacement: String) -> String {
        let regex = try! NSRegularExpression(pattern: regexString, options: [])
        return regex.stringByReplacingMatches(in: source,
                                              options: [],
                                              range: NSRange(location: 0, length: source.count),
                                              withTemplate: replacement)
    }
    
}
