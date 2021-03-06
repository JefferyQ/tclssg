#!/usr/bin/env tclsh
# Tclssg, a static website generator.
# Copyright (C) 2013, 2014, 2015, 2016, 2017 dbohdan.
# This code is released under the terms of the MIT license. See the file
# LICENSE for details.
package require Tcl 8.5
package require msgcat
package require struct
package require fileutil
package require textutil
package require html
package require sqlite3
package require csv
package require json

set PROFILE 0
if {$PROFILE} {
    package require profiler
    ::profiler::init
}

# Code conventions:
#
# Only use spaces for indentation. Keep the line width for code outside of
# templates under 80 characters.
#
# Procedures ("procs") have names-like-this; variables have namesLikeThis. "!"
# at the end of a proc's name means the proc modifies one or more of the
# variables it is passed by name (e.g., "unqueue!"). "?" in the same position
# means it returns a true/false value.

namespace eval tclssg {
    namespace export *
    namespace ensemble create

    variable version 1.0.3
    variable debugMode 1

    proc version {} {
        variable version
        return $version
    }

    proc configure {{scriptLocation .}} {
        # What follows is the configuration that is generally not supposed to
        # vary from project to project.
        set ::tclssg::config(scriptLocation) $scriptLocation

        set ::tclssg::config(libDir) \
                [file join $::tclssg::config(scriptLocation) lib]
        global auto_path
        lappend auto_path $::tclssg::config(libDir)

        package require tclssg-lib

        set ::tclssg::config(version) $::tclssg::version

        # Change the lines below to replace the Markdown package with, e.g.,
        # sundown.
        #set ::tclssg::config(markdownProcessor) /usr/local/bin/sundown
        set ::tclssg::config(markdownProcessor) :internal:

        # Source Markdown if needed.
        if {$::tclssg::config(markdownProcessor) eq ":internal:"} {
            package require Markdown
        }

        set ::tclssg::config(contentDirName) pages
        set ::tclssg::config(templateDirName) templates
        set ::tclssg::config(staticDirName) static
        set ::tclssg::config(dataDirName) data

        set ::tclssg::config(articleTemplateFilename) article.thtml
        set ::tclssg::config(documentTemplateFilename) bootstrap.thtml
        set ::tclssg::config(rssArticleTemplateFilename) rss-article.txml
        set ::tclssg::config(rssDocumentTemplateFilename) rss-feed.txml

        set ::tclssg::config(defaultFeedFilename) rss.xml ;# RSS output file.
        set ::tclssg::config(websiteConfigFilename) website.conf

        set ::tclssg::config(skeletonDir) \
                [file join $::tclssg::config(scriptLocation) skeleton]
        set ::tclssg::config(defaultInputDir) [file join website input]
        set ::tclssg::config(defaultOutputDir) [file join website output]
        set ::tclssg::config(defaultDebugDir) [file join website debug]

        set ::tclssg::config(templateBrackets) {<% %>}

        return
    }

    # Make one HTML article (HTML content enclosed in an <article>...</article>
    # tag) out of the content of page $id according to an article template.
    proc format-article {id articleTemplate {abbreviate 0} \
            {extraVariables {}}} {
        set cookedContent [tclssg pages get-data $id cookedContent]
        templating apply-template $articleTemplate $cookedContent \
                $id [list abbreviate $abbreviate {*}$extraVariables]
    }

    # Format an HTML document according to a document template. The document
    # content is taken from the variable content while page settings are taken
    # from pageData. This design allow you to make a document with custom
    # content, e.g., one with the content of multiple articles.
    proc format-document {content id documentTemplate} {
        templating apply-template $documentTemplate $content $id
    }

    # Generate an output document out of the pages listed in pageIds and
    # store it as $outputFile. The page data corresponding to the ids in
    # pageIds must be present in pages database table.
    proc write-output-file {outputFile topPageId articleTemplate
            documentTemplate {extraVariables {}} {silent 0}} {
        set inputFiles {}
        set gen {} ;# article content accumulator
        set first 1

        set pageIds [list $topPageId \
                {*}[tclssg pages get-data $topPageId articlesToAppend {}]]
        set isCollection [expr {[llength $pageIds] > 1}]

        foreach id $pageIds {
            append gen [format-article $id $articleTemplate [expr {!$first}] \
                    [list collectionPageId $topPageId \
                            collectionTopArticle \
                                    [expr {$isCollection && $first}] \
                            collection $isCollection \
                            {*}$extraVariables]]
            lappend inputFiles [tclssg pages get-data $id inputFile]
            set first 0
        }

        set subdir [file dirname $outputFile]

        if {![file isdir $subdir]} {
            puts "creating directory $subdir"
            file mkdir $subdir
        }

        if {!$silent} {
            puts "processing page file [lindex $inputFiles 0] into $outputFile"
        }
        # Take page settings form the first page.
        set output [format-document $gen $topPageId $documentTemplate]
        ::fileutil::writeFile $outputFile $output
    }

    # Return the path to a template file in $inputDir or (if it is not found in
    # $inputDir) in the project skeleton (::tclssg::config(skeletonDir)).  Name
    # resolution can later be made metadata-based.
    proc resolve-template-file-path {inputDir filename} {
        ::tclssg::utils::choose-dir $filename [
            list \
                [file join \
                        $inputDir \
                        $::tclssg::config(templateDirName)] \
                [file join \
                        $::tclssg::config(skeletonDir) \
                        $::tclssg::config(templateDirName)]
        ]
    }

    # Read the template file $filename from the appropriate directory.
    proc read-template-file-literal {inputDir filename} {
        set templateFile [resolve-template-file-path $inputDir $filename]
        return [read-file $templateFile]
    }

    # Read a template file. The template filename is set to
    # $websiteConfigKey, or, if that key is not present, $default.
    proc read-template-file {inputDir websiteConfigKey default} {
        set filename [
            tclssg pages get-website-config-setting \
                    $websiteConfigKey \
                    $default
        ]
        return [read-template-file-literal $inputDir $filename]
    }

    # Returns the contents of the file $filename in the data file subdirectory
    # of inputDir (usually "data").
    proc read-data-file {filename} {
        set dataDir [tclssg page get-website-config-setting dataDir ""]
        return [read-file [file join $dataDir [file tail $filename]]]
    }

    # Add one page or a series of pages that collect the articles of those pages
    # that are listed in pageIds. The number of pages added equals ([llength
    # pageIds] / $blogPostsPerFile) rounded up to the nearest whole number. Page
    # settings are taken from the page $topPageId and its content is prepended
    # to every output page. Used for making the blog index page.
    proc add-article-collection {pageIds topPageId} {
        set blogPostsPerFile [tclssg pages get-website-config-setting \
                blogPostsPerFile 10]
        set i 0
        set currentPageArticles {}
        set pageNumber 0
        set resultIds {}

        set blogIndexPageId \
                [tclssg pages get-website-config-setting blogIndexPageId ""]
        set tagPageId \
                [tclssg pages get-website-config-setting tagPageId ""]

        # Filter out pages to that set hideFromCollections to 1.
        set pageIds [::struct::list filterfor x $pageIds {
            ($x ne $topPageId) &&
            ![tclssg pages get-setting $x hideFromCollections 0]
        }]

        set prevIndexPageId {}

        foreach id $pageIds {
            lappend currentPageArticles $id
            # If there is enough posts for a page or this is the last post...
            if {($i == $blogPostsPerFile - 1) ||
                    ($id eq [lindex $pageIds end])} {

                set newInputFile \
                        [::tclssg::utils::add-number-before-extension \
                                [tclssg pages get-data $topPageId inputFile] \
                                [expr {$pageNumber + 1}] {-%d} 1]
                set newId [tclssg pages copy $topPageId 1]

                puts -nonewline "adding article collection $newInputFile"
                tclssg pages set-data \
                        $newId \
                        inputFile \
                        $newInputFile
                tclssg pages set-data \
                        $newId \
                        articlesToAppend \
                        $currentPageArticles

                if {$pageNumber > 0} {
                    tclssg pages set-setting $newId \
                            prevPage $prevIndexPageId
                    tclssg pages set-setting $prevIndexPageId \
                            nextPage $newId
                }

                tclssg pages set-setting $newId pageNumber $pageNumber

                puts " with posts [list [::struct::list mapfor x \
                        $currentPageArticles {tclssg pages get-data \
                                $x inputFile}]]"
                lappend resultIds $newId
                set prevIndexPageId $newId
                set i 0
                set currentPageArticles {}
                incr pageNumber
            } else {
                incr i
            }
        }
        return $resultIds
    }

    # For each tag add a page that collects the articles tagged with it using
    # add-article-collection.
    proc add-tag-pages {} {
        set tagPageId [tclssg pages get-website-config-setting tagPageId ""]
        if {[string is integer -strict $tagPageId]} {
            foreach tag [tclssg pages get-tag-list] {
                set taggedPages [tclssg pages with-tag $tag]
                set tempPageId [tclssg pages copy $tagPageId 1]
                set replacementRootname "[::tclssg::utils::slugify $tag]"

                # Update inputFile.
                set value [tclssg pages get-data $tempPageId inputFile ""]
                set newValue [file join \
                        {*}[lrange [file split $value] 0 end-1] \
                        "$replacementRootname[file extension $value]"]
                tclssg pages set-data \
                        $tempPageId \
                        inputFile \
                        $newValue

                set taggedPagesFiltered {}
                foreach id $taggedPages {
                    if {![tclssg pages get-setting $id hideFromCollections 0]} {
                        lappend taggedPagesFiltered $id
                    }
                }
                if {[llength $taggedPagesFiltered] == 0} {
                    continue
                }
                set resultIds [add-article-collection \
                        $taggedPagesFiltered $tempPageId]
                tclssg pages delete $tempPageId
                for {set i 0} {$i < [llength $resultIds]} {incr i} {
                    set id [lindex $resultIds $i]
                    tclssg pages add-tag-page $id $tag $i
                    tclssg pages set-setting $id tagPageTag $tag
                }
            }
        }
    }

    # Check the website config for errors that may not be caught elsewhere.
    proc validate-config {inputDir contentDir} {
        # Check that the website URL end with a '/'.
        set url [tclssg pages get-website-config-setting url {}]
        if {($url ne "") && ([string index $url end] ne "/")} {
            error {'url' in the website config does not end with '/'}
        }

        # Check for obsolete settings.
        if {([tclssg pages get-website-config-setting \
                pageVariables {}] ne {})  ||
                ([tclssg pages get-website-config-setting \
                        blogPostVariables {}] ne {})} {
            error "website config settings 'pageVariables' and\
                    'blogPostVariables' have been renamed\
                    'pageSettings' and 'blogPostSettings' respectively."
        }

        foreach settingContainer {pageSettings blogPostSettings} {
            foreach pageSetting {articleExtra bodyExtra headExtra} {
                if {([tclssg pages get-website-config-setting \
                [list $settingContainer $pageSetting] {}] ne {})} {
                    error "page settings 'articleExtra', 'bodyExtra' and\
                            'headExtra' have been renamed. See the\
                            documentation for details."
                }
            }
        }

        # Check that collection top pages actually exist.
        foreach varName {indexPage blogIndexPage tagPage} {
            set value [tclssg pages get-website-config-setting $varName ""]
            set path [file join $contentDir $value]
            if {($value ne "") && (![file exists $path])} {
                error "the file set for $varName in the website config does\
                    not exist: {$value} (actual path checked: $path)"
            }
        }
    }

    # Generate a sitemap for the static website. This requires the setting
    # "url" to be set in the website config.
    proc make-sitemap {outputDir} {
        set header [::tclssg::utils::trim-indentation {
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset
              xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9
                    http://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd">
        %s</urlset>
        }]

        set entry [::tclssg::utils::trim-indentation {
            <url>
              <loc>%s</loc>%s
            </url>
        }]

        set result ""
        set url [tclssg page get-website-config-setting url ""]
        if {$url eq ""} {
            error "can not generate the sitemap without a base URL specified"
        }
        foreach id [tclssg pages sorted-by-date] {
            # Exclude from the site map pages that are hidden from from
            # collections, blog index page beyond the first and tag pages.
            if {(![tclssg pages get-setting $id hideFromCollections 0]) &&
                    ([tclssg pages get-setting $id prevPage ""] eq "") &&
                    ([tclssg pages get-setting $id tagPageTag ""] eq "")} {
                set date [tclssg pages get-setting $id modifiedDateScanned ""]
                if {![string is integer -strict [lindex $date 0]]} {
                    # No valid modifiedDate, so will just use the sorting date
                    # for when the page was last modified.
                    set date [tclssg pages get-setting $id dateScanned ""]
                }
                if {[string is integer -strict [lindex $date 0]]} {
                    set lastmod "\n  <lastmod>[clock format [lindex $date 0] \
                            -format [lindex $date 1]]</lastmod>"
                } else {
                    set lastmod ""
                }
                append result [format $entry \
                        $url[::fileutil::relative $outputDir \
                                [tclssg pages get-output-file $id]] \
                        $lastmod]\n
            }
        }
        set result [format $header $result]
        return $result
    }

    # Synonymous setting names in the page frontmatter.
    variable settingSynonyms [dict create {*}{
        blog        blogPost
        updated     modifiedDate
        modified    modifiedDate
        hide        hideFromCollections
    }]

    # Load the content of the file $file into the page database.
    proc load-page {file} {
        variable settingSynonyms

        # May want to change the rawContent preloading behavior for very
        # large (larger than memory) websites.
        set rawContent [read-file $file]
        lassign [::tclssg::utils::get-page-settings $rawContent] \
            settings baseContent

        # Skip pages marked as drafts.
        if {[::tclssg::utils::dict-default-get 0 $settings draft]} {
            return
        }

        tclssg debugger save-intermediate \
                $file frontmatter-0-raw.tcl $settings
        tclssg debugger save-intermediate \
                $file content-0-raw $baseContent

        # Set the values for empty keys to those of their synonym keys, if
        # present.
        foreach {synonym varName} $settingSynonyms {
            if {![dict exists $settings $varName] &&
                    [dict exists $settings $synonym]} {
                dict set settings $varName [dict get $settings $synonym]
            }
        }

        # Parse date and modifiedDate into a Unix timestamp plus a format
        # string.
        set clockOptions {}
        set timezone [tclssg pages get-website-config-setting timezone ""]
        if {$timezone ne ""} {
            set clockOptions [list -timezone $timezone]
        }
        set dateScanned [::tclssg::utils::incremental-clock-scan \
                [::tclssg::utils::dict-default-get {} $settings date] \
                $clockOptions]
        dict set settings dateScanned $dateScanned
        set modifiedDateScanned [::tclssg::utils::incremental-clock-scan \
                [::tclssg::utils::dict-default-get {} \
                        $settings modifiedDate] \
                $clockOptions]
        dict set settings modifiedDateScanned $modifiedDateScanned

        # Add the current page to the page database with an appropriate
        # output filename.

        set id_ [tclssg pages add \
                        $file \
                        "" \
                        $rawContent \
                        "" \
                        [lindex $dateScanned 0]]

        tclssg pages add-tags $id_ \
                [::tclssg::utils::dict-default-get {} $settings tags]
        dict unset settings tags

        tclssg debugger save-intermediate \
                $file frontmatter-1-final.tcl $settings
        foreach {var value} $settings {
            tclssg pages set-setting $id_ $var $value
        }
    }

    # Produce an output file for page $id.
    proc compile-page {id prettyUrls outputDir
            articleTemplate documentTemplate} {
        set outputFile [tclssg pages get-output-file $id]

        # Relative path to the root directory of the output.
        tclssg pages set-data $id rootDirPath \
                [::fileutil::relative \
                        [file dirname $outputFile] \
                        $outputDir]

        # Render templates, first for the article then for the HTML
        # document.

        tclssg pages set-data $id cookedContent [
            tclssg templating prepare-content \
                    [tclssg pages get-data $id rawContent] \
                    $id \
        ]

        tclssg write-output-file \
                  [tclssg pages get-output-file $id] \
                    $id \
                    $articleTemplate \
                    $documentTemplate
    }

    # Generate RSS feeds.
    proc make-rss-feeds {inputDir outputDir prettyUrls} {
        # Set the default filename for RSS feeds if not present.
        set feedFilename [tclssg page get-website-config-setting \
                {rss feedFilename} $::tclssg::config(defaultFeedFilename)]
        tclssg pages set-website-config-setting \
                {rss feedFilename} $feedFilename

        # Read RSS templates.
        set rssArticleTemplate \
                [read-template-file $inputDir \
                        {rss template article} \
                        $::tclssg::config(rssArticleTemplateFilename)]
        set rssDocumentTemplate \
                [read-template-file $inputDir \
                        {rss template document} \
                        $::tclssg::config(rssDocumentTemplateFilename)]

        set rssFeedPageIds [tclssg pages \
                get-website-config-setting blogIndexPageId ""]

        if {[tclssg page get-website-config-setting {rss tagFeeds} 0]} {
            lappend rssFeedPageIds {*}[tclssg page get-tag-pages 0]
        }

        foreach pageId $rssFeedPageIds {
            set filename [$::tclssg::pages::rssFileCallback \
                    [tclssg pages get-data $pageId inputFile]]
            puts "writing RSS feed for page [tclssg page get-data \
                    $pageId inputFile] to $filename"
            write-output-file \
                    $filename \
                    $pageId \
                    $rssArticleTemplate \
                    $rssDocumentTemplate \
                    {} \
                    1
        }
    }

    # Process input files in $inputDir to produce a static website in
    # $outputDir.
    proc compile-website {inputDir outputDir debugDir websiteConfig} {
        tclssg pages init
        tclssg debugger init $inputDir $debugDir
        foreach {key value} $websiteConfig {
            tclssg pages set-website-config-setting $key $value
        }

        tclssg pages set-website-config-setting inputDir $inputDir
        set contentDir [file join $inputDir $::tclssg::config(contentDirName)]
        tclssg pages set-website-config-setting contentDir $contentDir
        tclssg pages set-website-config-setting dataDir \
                [file join $inputDir $::tclssg::config(dataDirName)]

        # Cache things globally, rather than per-directory, when using absolute
        # links.
        if {[tclssg pages get-website-config-setting absoluteLinks 0]} {
            set ::tclssg::templating::cache::alwaysFresh 1
        }

        validate-config $inputDir $contentDir

        set prettyUrls [tclssg pages get-website-config-setting prettyUrls 0]
        # A callback to determine outputFile from inputFile.
        set callback {{contentDir outputDir default extension prettyUrls} {
            upvar 1 inputFile inputFile
            set indexFile [expr {[file tail $inputFile] eq "index.md"}]
            if {($prettyUrls) || $indexFile} {
                set path [lrange \
                        [file split \
                                [::tclssg::utils::replace-path-root \
                                        $inputFile $contentDir $outputDir]] \
                        0 end-1]
                if {!$indexFile} {
                    lappend path [file rootname [file tail $inputFile]]
                }
                set result [file join {*}$path $default]
            } else {
                set result [file rootname \
                        [::tclssg::utils::replace-path-root \
                               $inputFile $contentDir $outputDir]].$extension
            }
            return $result
        }}
        proc ::tclssg::detOutputFile {inputFile} [list apply $callback \
            $contentDir \
            $outputDir \
            index.html \
            html \
            $prettyUrls]
        proc ::tclssg::detRssFile {inputFile} [list apply $callback \
            $contentDir \
            $outputDir \
            [tclssg pages get-website-config-setting feedFilename \
                    $::tclssg::config(defaultFeedFilename)] \
            xml \
            $prettyUrls]
        set ::tclssg::pages::outputFileCallback ::tclssg::detOutputFile
        set ::tclssg::pages::rssFileCallback ::tclssg::detRssFile

        variable settingSynonyms

        # Load the page files into the page database.
        foreach file [::fileutil::findByPattern $contentDir -glob *.md] {
            load-page $file
        }

        # Read template files.
        set articleTemplate [
            read-template-file $inputDir \
                    {template article} \
                    $::tclssg::config(articleTemplateFilename)]
        set documentTemplate [
            read-template-file $inputDir \
                    {template document} \
                    $::tclssg::config(documentTemplateFilename)]

        # Create a list of pages that are blog posts and a list of blog posts
        # that should be linked to in the blog sidebar.
        set blogPostIds [::struct::list filterfor id \
                [tclssg pages sorted-by-date] \
                {[tclssg pages get-setting $id blogPost 0]}]
        set sidebarPostIds [::struct::list filterfor id \
                $blogPostIds \
                {
                    ![tclssg pages get-setting $id hideFromSidebarLinks 0] &&
                    ![tclssg pages get-setting $id hideFromCollections 0]
                }]
        tclssg pages set-website-config-setting sidebarPostIds $sidebarPostIds

        # Add numerical ids that correspond to the special pages' input
        # filenames in the config to the database. Set the *PageId variables.
        foreach varName {indexPage blogIndexPage tagPage} {
            set value [file join $contentDir \
                    [tclssg pages get-website-config-setting $varName ""]]
            set id [tclssg pages input-file-to-id $value]
            tclssg pages set-website-config-setting ${varName}Id $id
            set ${varName}Id $id
        }
        # Replace the config outputDir, which may be relative to inputDir, with
        # the actual value of outputDir, which is not.
        tclssg pages set-website-config-setting outputDir $outputDir

        if {$blogIndexPageId ne ""} {
            add-article-collection $blogPostIds $blogIndexPageId
        }

        # For each tag that at least one blog post has add a collection page
        # with all blogs that have that tag.
        add-tag-pages

        # Do not process the pages only meant to be used as the "top" pages for
        # collections: the tag page and the original blog index page. The latter
        # will feature in the database twice if you do. Do not forget to delete
        # the links to them. The original blog index loaded from the disk will
        # share the outputFile with the first page of the one generated by add-
        # tag-pages meaning the links meant for one may end up pointing at the
        # other. This is really less obscure than it may seem.
        if {$tagPageId ne {}} {
            tclssg pages delete tagPageId
        }
        if {$blogIndexPageId ne {}} {
            set blogIndexInputFile \
                    [tclssg pages get-data $blogIndexPageId inputFile ""]
            set indexInputFile \
                    [tclssg pages get-data $indexPageId inputFile ""]

            tclssg pages delete $blogIndexPageId

            set blogIndexPageId \
                    [tclssg pages input-file-to-id $blogIndexInputFile]
            tclssg pages set-website-config-setting \
                    blogIndexPageId $blogIndexPageId
            # If the website index page is same as the blog index page update
            # the index page id.
            if {$indexInputFile eq $blogIndexInputFile} {
                tclssg pages set-website-config-setting \
                        indexPageId $blogIndexPageId
                set indexPageId $blogIndexPageId
            }
        }

        # Process page data into HTML output.
        foreach id [tclssg pages sorted-by-date] {
            compile-page $id $prettyUrls $outputDir \
                    $articleTemplate $documentTemplate
        }

        # Copy static files verbatim.
        ::tclssg::utils::copy-files \
                [file join $inputDir $::tclssg::config(staticDirName)] \
                $outputDir \
                1

        # Generate a sitemap.
        if {[tclssg page get-website-config-setting {sitemap enable} 0]} {
            set sitemapFile [file join $outputDir sitemap.xml]
            puts "writing sitemap to $sitemapFile"
            ::fileutil::writeFile $sitemapFile [tclssg make-sitemap $outputDir]
        }

        tclssg pages set-website-config-setting buildDate [clock seconds]

        if {[tclssg page get-website-config-setting {rss enable} 0]} {
            make-rss-feeds $inputDir $outputDir $prettyUrls
        }
    }

    # Load the website configuration file from the directory inputDir. Return
    # the raw content of the file without validating it. If $verbose is true
    # print the content.
    proc load-config {inputDir {verbose 1}} {
        set websiteConfig [
            read-file [file join $inputDir \
                    $::tclssg::config(websiteConfigFilename)]
        ]

        # Show loaded config to user (without the password values).
        if {$verbose} {
            puts "Loaded config file:"
            puts [::textutil::indent \
                    [::tclssg::utils::dict-format \
                            [::tclssg::utils::obscure-password-values \
                                    $websiteConfig] \
                            "%s %s\n" \
                            {
                                websiteTitle
                                headExtra
                                bodyExtra
                                start
                                moreText
                                sidebarNote
                            }] \
                    {    }]
        }

        return $websiteConfig
    }

    # Read the setting $settingName from website config in $inputDir
    proc read-path-setting {inputDir settingName} {
        set value [
            ::tclssg::utils::dict-default-get {} [
                ::tclssg::load-config $inputDir 0
            ] $settingName
        ]
        # Make relative path from config relative to inputDir.
        if {$value ne "" &&
                [::tclssg::utils::path-is-relative? $value]} {
            set value [
                ::fileutil::lexnormalize [
                    file join $inputDir $value
                ]
            ]
        }
        return $value
    }

    # Display the message and exit with exit code 1 if run as the main script
    # or cause a simple error otherwise.
    proc error-message {message} {
        if {[main-script?]} {
            puts $message
            exit 1
        } else {
            error $message
        }
    }

    # Display an error message and exit if inputDir does not exist or isn't a
    # directory.
    proc check-input-directory {inputDir} {
        set errorMessage {}
        if {![file exist $inputDir]} {
            error-message "inputDir \"$inputDir\" does not exist"
        } elseif {![file isdirectory $inputDir]} {
            error-message \
                    "inputDir \"$inputDir\" exists but is not a directory"
        }
    }

    # This proc is run if Tclssg is the main script.
    proc main {argv0 argv} {
        # Note: Deal with symbolic links pointing to the actual
        # location of the application to ensure that we look for the
        # supporting code in the actual location, instead from where
        # the link is.
        #
        # Note further the trick with ___; it ensures that the
        # resolution of symlinks also applies to the nominally last
        # segment of the path, i.e. the application name itself. This
        # trick then requires the second 'file dirname' to strip off
        # the ___ again after resolution.

        tclssg configure \
                [file dirname [file dirname [file normalize $argv0/___]]]

        # Version.
        set currentPath [pwd]
        catch {
            cd $::tclssg::config(scriptLocation)
            if {[file isdir \
                    [file join $::tclssg::config(scriptLocation) .git]]} {
                append ::tclssg::config(version) \
                        " (commit [string range [exec git rev-parse HEAD] 0 9])"
            }
        }
        cd $currentPath

        # Get command line options, including directories to operate on.
        set command [::tclssg::utils::unqueue! argv]

        set options {}
        while {[lindex $argv 0] ne "--" &&
                [string match -* [lindex $argv 0]]} {
            lappend options [string trimleft [::tclssg::utils::unqueue! argv] -]
        }
        set inputDir [::tclssg::utils::unqueue! argv]
        set outputDir [::tclssg::utils::unqueue! argv]
        set debugDir {}

        # Defaults for inputDir and outputDir.
        if {($inputDir eq "") && ($outputDir eq "")} {
            set inputDir $::tclssg::config(defaultInputDir)
            catch {
                set outputDir [read-path-setting $inputDir outputDir]
            }
            if {$outputDir eq ""} {
                set outputDir $::tclssg::config(defaultOutputDir)
            }
        } elseif {$outputDir eq ""} {
            catch {
                set outputDir [read-path-setting $inputDir outputDir]
            }
            if {$outputDir eq ""} {
                error-message [
                    ::tclssg::utils::trim-indentation {
                        error: no outputDir given.

                        please either a) specify both inputDir and outputDir or
                                      b) set outputDir in your configuration
                                         file.
                    }
                ]
            }
        }
        if {$debugDir eq ""} {
            catch {
                set debugDir [read-path-setting $inputDir debugDir]
            }
            if {$debugDir eq ""} {
                set debugDir $::tclssg::config(defaultDebugDir)
            }
        }

        # Check if inputDir exists for commands that require it.
        if {($command in [::struct::list map \
                    [info commands ::tclssg::command::*] \
                    {namespace tail}]) &&
                ($command ni [list "help" "init" "version"])} {
            check-input-directory $inputDir
        }

        # Execute command.
        if {[catch {
                tclssg command $command $inputDir $outputDir $debugDir $options
            } errorMessage]} {
            set errorMessage "\n*** error: $errorMessage ***"
            if {$::tclssg::debugMode} {
                global errorInfo
                append errorMessage "\nTraceback:\n$errorInfo"
            }
            error-message $errorMessage
        }
    }
} ;# namespace tclssg

# Check if we were run as the primary script by the interpreter. Code from
# http://wiki.tcl-lang.org/40097.
proc main-script? {} {
    global argv0

    if {[info exists argv0] &&
            [file exists [info script]] &&
            [file exists $argv0]} {
        file stat $argv0 argv0Info
        file stat [info script] scriptInfo
        expr {$argv0Info(dev) == $scriptInfo(dev)
           && $argv0Info(ino) == $scriptInfo(ino)}
    } else {
        return 0
    }
}

if {[main-script?]} {
    ::tclssg::main $argv0 $argv
    if {$PROFILE} {
        puts [::profiler::sortFunctions exclusiveRuntime]
    }
}
