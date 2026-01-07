import ballerina/io;
import ballerina/os;
import ballerina/http;
import ballerina/file;
import ballerina/time;
import ballerina/lang.regexp;
import ballerinax/github;

// Repository record type
type Repository record {|
    string owner;
    string repo;
    string name;
    string lastVersion;
    string lastChecked;
    string specPath;
    string releaseAssetName;
|};

// Update result record
type UpdateResult record {|
    Repository repo;
    string oldVersion;
    string newVersion;
    string downloadUrl;
    string localPath;
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Download OpenAPI spec from release asset or repo
function downloadSpec(github:Client githubClient, string owner, string repo, 
                     string assetName, string tagName, string localPath, string specPath) returns error? {
    
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
    
    // Create directory if it doesn't exist
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }
    
    // Write to file
    if content is string {
        check io:fileWriteString(localPath, content);
    } else if content is byte[] {
        check io:fileWriteBytes(localPath, content);
    } else {
        return error("Failed to get content from response");
    }
    
    io:println(string `  ✅ Downloaded to ${localPath}`);
    return;
}

// Execute git command
function executeGitCommand(string command) returns error? {
    // In GitHub Actions, we'll use os:exec or system commands
    // For now, this is a placeholder - GitHub Actions will handle git commands
    io:println(string `  Executing: ${command}`);
    return;
}

// Create Pull Request
function createPullRequest(github:Client githubClient, string owner, string repo, 
                          string branchName, string baseBranch, string title, 
                          string body) returns string|error {
    
    io:println("\n🔗 Creating Pull Request...");
    
    // Create PR using GitHub client
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

// Get current repository info from git
function getCurrentRepo() returns [string, string]|error {
    // This will be provided via environment variables in GitHub Actions
    string? githubRepo = os:getEnv("GITHUB_REPOSITORY");
    if githubRepo is string {
        string[] parts = regexp:split(re `/`, githubRepo);
        if parts.length() == 2 {
            return [parts[0], parts[1]];
        }
    }
    return error("Could not determine repository from GITHUB_REPOSITORY env var");
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
    
    // Load repositories from repos.json (one level up from dependabot/)
    json reposJson = check io:fileReadJson("../repos.json");
    Repository[] repos = check reposJson.cloneWithType();
    
    io:println(string `Found ${repos.length()} repositories to monitor.\n`);
    
    // Track updates
    UpdateResult[] updates = [];
    
    // Check each repository
    foreach Repository repo in repos {
        io:println(string `Checking: ${repo.name} (${repo.owner}/${repo.repo})`);
        
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
                io:println(string `  Latest version: ${tagName}`);
                if publishedAt is string {
                    io:println(string `  Published: ${publishedAt}`);
                }
                
                if hasVersionChanged(repo.lastVersion, tagName) {
                    io:println(string `  ✅ UPDATE AVAILABLE!`);
                    
                    // Define local path for the spec (relative to api-specs root)
                    string localPath = string `../specs/${repo.owner}/${repo.repo}/${repo.releaseAssetName}`;
                    
                    // Download the spec
                    error? downloadResult = downloadSpec(
                        githubClient, 
                        repo.owner, 
                        repo.repo, 
                        repo.releaseAssetName, 
                        tagName, 
                        localPath,
                        repo.specPath
                    );
                    
                    if downloadResult is error {
                        io:println(string `  ❌ Download failed: ${downloadResult.message()}`);
                    } else {
                        // Track the update
                        updates.push({
                            repo: repo,
                            oldVersion: repo.lastVersion,
                            newVersion: tagName,
                            downloadUrl: string `https://github.com/${repo.owner}/${repo.repo}/releases/tag/${tagName}`,
                            localPath: localPath
                        });
                        
                        // Update the repo record
                        repo.lastVersion = tagName;
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
            string summary = string `- ${update.repo.name}: ${update.oldVersion} → ${update.newVersion}`;
            io:println(summary);
            updateSummary.push(summary);
        }
        
        // Update repos.json (one level up)
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
        
        string prBody = string `## OpenAPI Specification Updates

This PR contains automated updates to OpenAPI specifications detected by the Dependabot monitor.

### Changes:
${summaryContent}

### Checklist:
- [ ] Review specification changes
- [ ] Verify connector generation works
- [ ] Run tests
- [ ] Update documentation if needed

---
🤖 This PR was automatically generated by the OpenAPI Dependabot`;
        
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
            io:println(string `\n✨ Done! Review the PR at: ${prUrl}`);
        } else {
            io:println(string `\n⚠️  PR creation failed: ${prUrl.message()}`);
            io:println("Changes are committed. Please create PR manually.");
        }
        
    } else {
        io:println("✨ All specifications are up-to-date!");
    }
}