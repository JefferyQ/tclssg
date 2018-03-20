# Tclssg, a static website generator.
# Copyright (c) 2013, 2014, 2015, 2016, 2017, 2018
# dbohdan and contributors listed in AUTHORS. This code is released under
# the terms of the MIT license. See the file LICENSE for details.

# Config file parsing and validation.
namespace eval ::tclssg::config {
    namespace export *
    namespace ensemble create
    namespace path ::tclssg

    variable schema {
        abbreviate
        blogDefaults
        blogPostsPerFile
        charset
        {comments disqusShortname}
        {comments engine}
        copyright
        {deployCopy path}
        {deployCustom end}
        {deployCustom file}
        {deployCustom start}
        {deployFtp password}
        {deployFtp path}
        {deployFtp port}
        {deployFtp server}
        {deployFtp user}
        enableMacros
        inputDir
        locale
        {markdown converter}
        {markdown tabs}
        maxSidebarLinks
        maxTagCloudTags
        outputDir
        pageDefaults
        prettyURLs
        {rss enable}
        {rss feedDescription}
        {rss posts}
        {rss tagFeeds}
        {server host}
        {server port}
        sidebarPostIds
        {sitemap enable}
        sortTagsBy
        timezone
        url
        websiteTitle
    }

    # Load the website configuration file from the directory inputDir. Return
    # the raw content of the file without validating it. If $verbose is true
    # print the content.
    proc load {inputDir {verbose 1}} {
        set configRaw [utils::read-file [file join $inputDir website.conf]]
        set config [utils::remove-comments $configRaw]

        # Show loaded config to user (without the password values).
        if {$verbose} {
            set formatted \
                [utils::dict-format [utils::obscure-password-values $config] \
                                    "%s %s\n" \
                                    {
                                        websiteTitle
                                        headExtra
                                        bodyExtra
                                        start
                                        moreText
                                        sidebarNote
                                    }]
            log::info {loaded config file}
            log::info [::textutil::indent $formatted {    }]
        }
        validate $config
        return $config
    }

    # Check the website config for errors that may not be caught elsewhere.
    proc validate config {
        # Check that the website URL ends with a '/'.
        set url [utils::dict-default-get {} $config url]
        if {($url ne {}) && ([string index $url end] ne "/")} {
            error {"url" in the website config does not end with "/"}
        }
    }
}

package provide tclssg::config 0
