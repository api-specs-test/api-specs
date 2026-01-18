import ballerina/io;
import ballerina/os;
import ballerina/http;
import ballerina/file;
import ballerina/time;
import ballerina/lang.regexp;
import ballerinax/github;

// Repository record type
type Repository record {|
    string vendor;
    string api;
    string owner;
    string repo;
    string name;
    string lastVersion;
    string specPath;
    string releaseAssetName;
    string baseUrl;
    string documentationUrl;
    string description;
    string[] tags;
|};

// Update result record
type UpdateResult record {|
    Repository repo;
    string oldVersion;
    string newVersion;
    string apiVersion;
    string downloadUrl;
    string localPath;
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Extract version from OpenAPI spec content
function extractApiVersion(string content) returns string|error {
    // Try to find "version:" under "info:" section
    // This is a simple regex-based extraction
    
    // Split content by lines
    string[] lines = regexp:split(re `\n`, content);
    boolean inInfoSection = false;
    
    foreach string line in lines {
        string trimmedLine = line.trim();
        
        // Check if we're entering info section
        if trimmedLine == "info:" {
            inInfoSection = true;
            continue;
        }
        
        // If we're in info section, look for version
        if inInfoSection {
            // Exit info section if we hit another top-level key
            if !line.startsWith(" ") && !line.startsWith("\t") && trimmedLine != "" && !trimmedLine.startsWith("#") {
                break;
            }
            
            // Look for version field
            if trimmedLine.startsWith("version:") {
                // Extract version value
                string[] parts = regexp:split(re `:`, trimmedLine);
                if parts.length() >= 2 {
                    string versionValue = parts[1].trim();
                    // Remove quotes if present
                    versionValue = removeQuotes(versionValue);
                    return versionValue;
                }
            }
        }
    }
    
    return error("Could not extract API version from spec");
}

// Download OpenAPI spec from release asset or repo
function downloadSpec(github:Client githubClient, string owner, string repo, 
                     string assetName, string tagName, string specPath) returns string|error {
    
    io:println(string `  📥 Downloading ${assetName}...`);
    
    string? downloadUrl = ();
    
    // Try to get from release assets first
    github:Release|error release = githubClient->/repos/[owner]/[repo]/releases/tags/[tagName]();
    
    if release is github:Release {
        github:ReleaseAsset[]? assets = release.assets;
        if assets is github:ReleaseAsset[] {
            foreach github:ReleaseAsset asset in assets {
                if asset.name == assetName {
                    downloadUrl = asset.browser_download_url;
                    io:println(string `  ✅ Found in release assets`);
                    break;
                }
            }
        }
    }
    
    // If not found in assets, try direct download from repo
    if downloadUrl is () {
        io:println(string `  ℹ️  Not in release assets, downloading from repository...`);
        downloadUrl = string `https://raw.githubusercontent.com/${owner}/${repo}/${tagName}/${specPath}`;
    }
    
    // Download the file
    http:Client httpClient = check new (<string>downloadUrl);
    http:Response response = check httpClient->get("");
    
    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${<string>downloadUrl}`);
    }
    
    // Get content
    string|byte[]|error content = response.getTextPayload();
    
    if content is error {
        return error("Failed to get content from response");
    }
    
    string textContent;
    if content is string {
        textContent = content;
    } else {
        // Convert bytes to string
        textContent = check string:fromBytes(content);
    }
    
    io:println(string `  ✅ Downloaded spec`);
    return textContent;
}

// Save spec to file
function saveSpec(string content, string localPath) returns error? {
    // Create directory if it doesn't exist
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }
    
    // Write as openapi.yaml (always YAML format)
    check io:fileWriteString(localPath, content);
    io:println(string `  ✅ Saved to ${localPath}`);
    return;
}

// Create metadata.json file
function createMetadataFile(Repository repo, string version, string dirPath) returns error? {
    json metadata = {
        "name": repo.name,
        "baseUrl": repo.baseUrl,
        "documentationUrl": repo.documentationUrl,
        "description": repo.description,
        "tags": repo.tags,
        "version": version
    };
    
    string metadataPath = string `${dirPath}/.metadata.json`;
    check io:fileWriteJson(metadataPath, metadata);
    io:println(string `  ✅ Created metadata at ${metadataPath}`);
    return;
}

// Get current repository info from git
function getCurrentRepo() returns [string, string]|error {
    string? githubRepo = os:getEnv("GITHUB_REPOSITORY");
    if githubRepo is string {
        string[] parts = regexp:split(re `/`, githubRepo);
        if parts.length() == 2 {
            return [parts[0], parts[1]];
        }
    }
    return error("Could not determine repository from GITHUB_REPOSITORY env var");
}

// Create Pull Request
function createPullRequest(github:Client githubClient, string owner, string repo, 
                          string branchName, string baseBranch, string title, 
                          string body) returns string|error {
    
    io:println("\n🔗 Creating Pull Request...");
    
    github:PullRequest pr = check githubClient->/repos/[owner]/[repo]/pulls.post({
        title: title,
        body: body,
        head: branchName,
        base: baseBranch
    });
    
    string prUrl = pr.html_url;
    io:println(string `✅ Pull Request created successfully!`);
    io:println(string `🔗 PR URL: ${prUrl}`);
    
    // Add labels to the PR
    int prNumber = pr.number;
    _ = check githubClient->/repos/[owner]/[repo]/issues/[prNumber]/labels.post({
        labels: ["openapi-update", "automated", "dependencies"]
    });
    io:println("🏷️  Added labels to PR");
    
    return prUrl;
}

// Remove quotes from string
function removeQuotes(string s) returns string {
    string result = "";
    foreach int i in 0 ..< s.length() {
        string c = s.substring(i, i + 1);
        if c != "\"" && c != "'" {
            result += c;
        }
    }
    return result;
}

// Main monitoring function
public function main() returns error? {
    io:println("=== Dependabot OpenAPI Monitor ===");
    io:println("Starting OpenAPI specification monitoring...\n");
    
    // Get GitHub token
    string? token = os:getEnv("GH_TOKEN");
    if token is () {
        io:println("❌ Error: GH_TOKEN environment variable not set");
        io:println("Please set the GH_TOKEN environment variable before running this program.");
        return;
    }
    
    string tokenValue = <string>token;
    
    // Validate token
    if tokenValue.length() == 0 {
        io:println("❌ Error: GH_TOKEN is empty!");
        return;
    }
    
    io:println(string `🔍 Token loaded (length: ${tokenValue.length()})`);
    
    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token: tokenValue
        }
    });
    
    // Load repositories from repos.json
    json reposJson = check io:fileReadJson("../repos.json");
    Repository[] repos = check reposJson.cloneWithType();
    
    io:println(string `Found ${repos.length()} repositories to monitor.\n`);
    
    // Track updates
    UpdateResult[] updates = [];
    
    // Check each repository
    foreach Repository repo in repos {
        io:println(string `Checking: ${repo.name} (${repo.vendor}/${repo.api})`);
        
        // Get latest release
        github:Release|error latestRelease = githubClient->/repos/[repo.owner]/[repo.repo]/releases/latest();
        
        if latestRelease is github:Release {
            string tagName = latestRelease.tag_name;
            string? publishedAt = latestRelease.published_at;
            boolean isDraft = latestRelease.draft;
            boolean isPrerelease = latestRelease.prerelease;
            
            if isPrerelease || isDraft {
                io:println(string `  ⏭️  Skipping pre-release: ${tagName}`);
            } else {
                io:println(string `  Latest release tag: ${tagName}`);
                if publishedAt is string {
                    io:println(string `  Published: ${publishedAt}`);
                }
                
                if hasVersionChanged(repo.lastVersion, tagName) {
                    io:println("  ✅ UPDATE AVAILABLE!");
                    // Download the spec to extract version
                    string|error specContent = downloadSpec(
                        githubClient, 
                        repo.owner, 
                        repo.repo, 
                        repo.releaseAssetName, 
                        tagName,
                        repo.specPath
                    );
                    if specContent is error {
                        io:println("  ❌ Download failed: " + specContent.message());
                    } else {
                        // Extract API version from spec
                        string apiVersion = "";
                        var apiVersionResult = extractApiVersion(specContent);
                        if apiVersionResult is error {
                            io:println("  ⚠️  Could not extract API version, using tag: " + tagName);
                            // Fall back to tag name (remove 'v' prefix if exists)
                            apiVersion = tagName.startsWith("v") ? tagName.substring(1) : tagName;
                        } else {
                            apiVersion = apiVersionResult;
                            io:println("  📌 API Version: " + apiVersion);
                        }
                        // Structure: openapi/{vendor}/{api}/{apiVersion}/
                        string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;
                        string localPath = versionDir + "/openapi.yaml";
                        // Save the spec
                        error? saveResult = saveSpec(specContent, localPath);
                        if saveResult is error {
                            io:println("  ❌ Save failed: " + saveResult.message());
                        } else {
                            // Create metadata.json
                            error? metadataResult = createMetadataFile(repo, apiVersion, versionDir);
                            if metadataResult is error {
                                io:println("  ⚠️  Metadata creation failed: " + metadataResult.message());
                            }
                            // Track the update
                            updates.push({
                                repo: repo,
                                oldVersion: repo.lastVersion,
                                newVersion: tagName,
                                apiVersion: apiVersion,
                                downloadUrl: "https://github.com/" + repo.owner + "/" + repo.repo + "/releases/tag/" + tagName,
                                localPath: localPath
                            });
                            // Update the repo record
                            repo.lastVersion = tagName;
                        }
                    }
                } else {
                    io:println(string `  ℹ️  No updates`);
                }
            }
        } else {
            string errorMsg = latestRelease.message();
            if errorMsg.includes("404") {
                io:println(string `  ❌ Error: No releases found for ${repo.owner}/${repo.repo}`);
            } else if errorMsg.includes("401") || errorMsg.includes("403") {
                io:println(string `  ❌ Error: Authentication failed`);
            } else {
                io:println(string `  ❌ Error: ${errorMsg}`);
            }
        }
        
        io:println("");
    }
    
    // Report updates
    if updates.length() > 0 {
        io:println(string `\n🎉 Found ${updates.length()} updates:\n`);
        
        // Create update summary
        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string summary = string `- ${update.repo.vendor}/${update.repo.api}: ${update.oldVersion} → ${update.newVersion} (API v${update.apiVersion})`;
            io:println(summary);
            updateSummary.push(summary);
        }
        
        // Update repos.json
        check io:fileWriteJson("../repos.json", repos.toJson());
        io:println("\n✅ Updated repos.json with new versions");
        
        // Write update summary
        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("../UPDATE_SUMMARY.txt", summaryContent);
        
        // Get current date for branch name
        time:Utc currentTime = time:utcNow();
        string timestamp = string `${time:utcToString(currentTime).substring(0, 10)}-${currentTime[0]}`;
        string branchName = string `openapi-update-${timestamp}`;
        
        // Get repository info
        [string, string]|error repoInfo = getCurrentRepo();
        if repoInfo is error {
            io:println("⚠️  Could not create PR automatically. Changes are ready in working directory.");
            io:println("Please create a PR manually with the following branch name:");
            io:println(string `  ${branchName}`);
            return;
        }
        
        string owner = repoInfo[0];
        string repoName = repoInfo[1];
        
        // Create PR title and body
        time:Civil civil = time:utcToCivil(currentTime);
        string prTitle = string `Update OpenAPI Specifications - ${civil.year}-${civil.month}-${civil.day}`;
        
        // Build Files Changed section
        string filesChangedContent = "";
        foreach var u in updates {
            filesChangedContent = filesChangedContent + "- `" + u.localPath + "` (API v" + u.apiVersion + ")\n";
        }
        string prBody = "## OpenAPI Specification Updates\n\n" +
            "This PR contains automated updates to OpenAPI specifications detected by the Dependabot monitor.\n\n" +
            "### Changes:\n" + summaryContent + "\n" +
            "### Files Changed:\n" + filesChangedContent + "\n" +
            "### Checklist:\n" +
            "- [ ] Review specification changes\n" +
            "- [ ] Verify connector generation works\n" +
            "- [ ] Run tests\n" +
            "- [ ] Update documentation if needed\n\n" +
            "---\n" +
            "🤖 This PR was automatically generated by the OpenAPI Dependabot";
        
        // Create the PR
        string|error prUrl = createPullRequest(
            githubClient,
            owner,
            repoName,
            branchName,
            "main",
            prTitle,
            prBody
        );
        if prUrl is string {
            io:println("\n✨ Done! Review the PR at: " + prUrl);
        } else {
            io:println("\n⚠️  PR creation failed: " + prUrl.message());
            io:println("Changes are committed. Please create PR manually.");
        }
        
    } else {
        io:println("✨ All specifications are up-to-date!");
    }
}