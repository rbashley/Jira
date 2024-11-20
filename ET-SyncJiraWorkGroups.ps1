#region Comment Header
<#
    .SYNOPSIS
        Syncronize Jira groups to correct permissions in Jira.
    .Description
        This script is a PowerShell script used to interact with the Jira API. It includes several parameters 
        that allow the user to specify whether they are targeting a production or staging environment, the name 
        of the target organization, and a string of group information that includes the ID and source 
        organizations for each group.

        The functions included in this script is:

        Get-Header
            This Fuction takes the credential title in Credential Manager to generate a token for use in the API calls
        Start-JiraSync
            This Function handles the order of operations for the script and is the first function called in the script
        Get-AllUsersInParentGroup
            This Function takes the group passed from "Get-UsersInJiraOrg" and grabs users in chucks and ensures there is no looping or empty responses
        Get-UsersInJiraOrg
            This Function Calls "Get-AllUsersInParentGroup" for each group called passed to the script and collates them into an array
        Add-UsersToJiraOrg
            This Function takes entire returned user block and splits it up and pushes it to the appropriate Jira OrgID


    .NOTES
        Name: ET-SyncJiraWorkGroups
        Author: Randall Ashley, Amit Jambusaria, Vasil Nikolov
        Company: Wayfair
        DateCreated:  09/01/2022
        DateModified: 11/05/2022
                      11/21/2022
                      02/01/2023
                      02/06/2023
                      02/11/2023
                      02/20/2023
                      02/21/2023
                      06/22/2023
        Version: 3.0
#>

#endregion

#Define Variables

[CmdletBinding()]
    
Param(

    # Specifies if this is Prod (True/1) or Stg (False/0)
    [System.Byte] $Prod = [System.Byte] ($env:JiraProd -like '[Tt]rue'),

    # Specifies the Group Name to targeted
    [System.String] $TargetOrgName = $env:JiraTargetOrgName,

    # Contains the Org Slush - it maintains the relationship between name prod and stg groups
    # Format ([Name]; [Stg ID],[Prod ID]; [Workgroup],[Workgroup]...)
    # This will be inputed as a comma seperated list ex: "(Frontline; 5,217; wg_9159,wg_13123,wg_13119)"
    [System.String] $OrgSlush = $env:JiraOrgSlush,

    # Contains the Prod and Stg URL format [Stg],[Prod]
    [System.String] $Url = $($env:JiraURL.split(',').trim())[$Prod],

    # Contains the Prod and Stg UserName format [Stg],[Prod]
    [System.String] $UserName = $($env:JiraUserName.split(',').trim())[$Prod],

    #Specifies the name of the Azure Key Vault
    [String] $KeyVaultName  = $env:KeyVaultName,
    
    #Specifies the name of the Azure Key Vault subscription
    [String] $subscriptionId = $env:subscriptionId
    
    )

#endregion


#####Add this code at the beggining of your script to connect to Azure and Register the Key Vault
[Array] $modules = @(
    'Az.Accounts', 
    'Az.KeyVault',
    'Microsoft.PowerShell.SecretManagement'
)

#region module dependency
foreach ($module in $modules) {
    if (-not (Get-Module $module)) {
        try {
            Import-Module $module -ErrorAction 'Stop'
            Write-Verbose -Message "Imported module $module" -Verbose
        }
        catch {
            $message = "Unable to Load $module. Processing Aborted. Exception message: $($_.exception.message)"
            Write-Verbose -Message $message -Verbose
                
            throw $_.Exception
        }
    }
}
#endregion

#region Azure Connect 
try {
    $azAccount = Connect-AzAccount -Identity -ErrorAction 'Stop'

    Write-Verbose -Message "Connected to Azure with account $($azAccount.Context.Account.Id)" -Verbose
}
catch {
    Write-Verbose -Message "Failed to connect to Azure using the Jenkins Node's identity. $($_.Exception.Message)" -Verbose

    throw $_.Exception
}
#endregion

#region Register Azure Key Vault
Write-Verbose -Message "Checking if Secret Vault already registered" -Verbose
if (Get-SecretVault -Name $KeyVaultName  -ErrorAction SilentlyContinue) {
    Write-Verbose -Message "$($KeyVaultName ) Secret Vault is already registered" -Verbose
}
else {
    Write-Verbose -Message "Registering $($KeyVaultName ) Secret Vault" -Verbose
    Register-SecretVault -Name $KeyVaultName  -ModuleName Az.KeyVault -VaultParameters @{ AZKVaultName = $KeyVaultName ; SubscriptionId = $subscriptionId } -Verbose
}
#endregion
#####

<#

Begin DeSlush

Processes a variable called $OrgSlush that contains a string of group information.

The code splits the $OrgSlush string into an array of groups using a regular expression pattern that 
matches anything between parentheses. It then creates a hashtable object called $groups and uses a foreach loop to iterate 
through each group in the array.

Inside the loop, the code checks if the current group is not an empty string, and if not, it splits the 
group into an array using semicolons as the delimiter. It then adds the first item in the array (which is 
the group name) as a key in the $groups hashtable, with the corresponding value being an array containing 
the group's ID and a list of its source organizations.

The code then splits the source organizations list and ID using commas as the delimiter, trims any 
whitespace, and assigns the resulting arrays to the appropriate keys in the $groups hashtable.

Finally, the code uses the $TargetOrgName variable to retrieve the source organizations array for the target 
group and the $Prod variable to retrieve the corresponding organization ID.

Note that the code also includes error handling that will output a message and exit with an error code of 1 
if no groups or non-empty groups are found in the $OrgSlush string.

#>

[System.Array] $orgGroups = $OrgSlush.split('(.*)').Trim()
[System.Collections.Hashtable] $groups = [System.Collections.Hashtable]::new($orgGroups.Length)

if(-not $orgGroups) {

    Write-Host "No groups extracted from `$OrgSlush"

    Exit 1

}

else {

    ForEach ($group in $orgGroups){

        if('' -ne $group){
            [System.Array] $tempvar = $group.split(';')
            $groups[$tempvar[0]] = $tempvar[1..2]
            
            $groups[$tempvar[0]][0] = $groups[$tempvar[0]][0].split(',').trim()
            $groups[$tempvar[0]][1] = $groups[$tempvar[0]][1].split(',').trim().ToLower()

            write-host $groups[$tempvar[0][0]]
            $groups[$tempvar[0][1]]
        }
    }

    if(-not $groups) {

        Write-Host "No Non-Empty groups extracted from `$OrgSlush"

        Exit 1

    }

}

#End DeSlush

<#
This is a PowerShell function called Get-Header, which retrieves a header for API requests to a Jira 
instance. The header includes authentication information, content type, and an API opt-in flag.

The function takes in a single parameter, $UserName, which specifies the name of the user whose 
credentials will be used to authenticate API requests. The function uses the Get-StoredCredential 
cmdlet to retrieve the credentials for the specified user, which are then encoded as a base64 string 
and included in the header. The header is returned as a hash table.
#>
Function Get-Header(){

    [CmdletBinding()]

    Param(

        [System.String] $UserName

    )

    try {

        ###Use the below lines of code to retrieve secrets from Azure Key Vault
        $token = Get-Secret -Vault $KeyVaultName  -Name $UserName -AsPlainText
        ###

        if($null -ne $token){

            Write-Verbose "Token Recieved" -Verbose

        }
        else {

            Write-Verbose "Token not found Exiting..." -Verbose

            Exit 1

        }

    }
catch {

        Write-Verbose "Failed Get-StoredCredential" -Verbose

        Exit 1

    }

    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($token.username):$($token.password)"))

    $header = @{
        Authorization = "Basic $base64AuthInfo"
        "content-type" = "application/json"
        'X-ExperimentalApi' = 'opt-in'

    }

    return $header

}

<#
This script is a PowerShell function named "Get-AllUsersInParentGroup". The function takes two parameters:

$sourceorgs is an array of strings that represent the names of source organizations.
$BaseURL is a string that represents the base URL for the Jira instance.
The function starts by defining an empty array $Users to store the names of the users. Then, it iterates over 
the elements of the $sourceorgs array using a for loop.

For each iteration, the function calls another function named Get-UsersInJiraOrg and passes the -OrgName 
parameter with the current organization name and the -BaseURL parameter with the provided base URL. The 
function also sets the -PageSize parameter to 50 and the -StartAt parameter to 0.

The result of the Get-UsersInJiraOrg function is then appended to the $Users array.

Finally, the function returns the names of the users stored in the $Users array.

Note: The Write-Verbose cmdlet writes a message to the verbose output stream if the verbose parameter is 
specified when calling the function.
#>

Function Get-AllUsersInParentGroup {

    [CmdletBinding()]

    Param(
    
    [System.Array] $sourceorgs,
    [System.String] $BaseURL
    
    )

    $Users = @()

    for($i = 0; $i -lt $sourceorgs.length; $i++){

        Write-Verbose "Getting group $($sourceorgs[$i])" -Verbose

        $userchunk = (Get-UsersInJiraOrg -OrgName $sourceorgs[$i] -BaseURL $BaseURL -PageSize 50 -StartAt 0)

        if(-not $userchunk){

            Write-Verbose "Blank Return from Get-UsersInJira - Org: $($sourceorgs[$i]), URL: $BaseURL"

        }
        else {

            $Users = $Users + $userchunk

        }

    }

    return $Users.name

}

<#
This is a PowerShell function named "Get-UsersInJiraOrg" that retrieves all the users belonging to a 
specified group (referred to as "Org" in the function). It uses Jira's REST API to make the request 
and expects four parameters to be passed to the function:

OrgName: The name of the group in Jira whose members are to be retrieved.
BaseURL: The base URL of the Jira instance.
PageSize: The number of results to be returned in each block.
StartAt: The starting index of the block to be retrieved.
The function first initializes an empty array called $Users and a boolean variable called $iterate set 
to true. The while loop continues until $iterate is set to false.

Within the loop, the function constructs the URL for the API call using the specified parameters and 
makes the request using Invoke-RestMethod cmdlet. If the response contains any values, the function 
checks if it is the first block or not. If it's not the first block, it checks for duplicate responses 
by comparing the current block with the previous block. If the current block is not a duplicate, it is 
added to the $Users array. If the response is empty, the function sets $iterate to false and exits the 
loop.

The function then checks if the response is the last block or not. If it's not the last block, it 
updates the $StartAt variable to retrieve the next block. If it's the last block, the function sets 
$iterate to false and exits the loop.

If any error occurs during the API call, the function catches it and sets $iterate to false, which causes 
the loop to exit.

Finally, the function returns the $Users array containing all the users in the specified group.
#>
Function Get-UsersInJiraOrg {

    [CmdletBinding()]

    Param(
    
    [System.String] $OrgName,
    [System.String] $BaseURL,
    [System.Int32] $PageSize,
    [System.Int32] $StartAt
    
    )

    $Users = @()
    $iterate = $true

    While($iterate){

        try {

            $conURL = $BaseURL+"/rest/api/2/group/member?includeInactiveUsers=false&maxResults=$PageSize&groupname=$OrgName&startAt=$StartAt"

            Write-Verbose "Making API call to $conURL" -Verbose

            $request = Invoke-RestMethod -Uri $conURL -Method Get -Headers $(Get-Header -UserName $UserName)

            if($null -ne $request.values) {

                if($StartAt -ge 1) {

                    $previousBlock = $Users[$($StartAt - $PageSize)..$($PageSize-1)] | Sort-Object -Descending
                    $currentBlock = $request.values | Sort-Object -Descending

                    if($previousBlock -ne $currentBlock){

                        $Users = $Users + $request.values

                    }
                    else {

                        Write-Verbose "Returned duplicate Response" -Verbose
                        $iterate = $false

                    }

                }
                else {

                    Write-Verbose "Is First Block"
                    $Users = $Users + $request.values

                }

            }
            else {

                Write-Verbose "Returned Empty Response" -Verbose

                $iterate = $false

            }

            if($request.isLast -eq $false){
                
                $StartAt = $StartAt+$PageSize+1;
            }
            else {
                        
                Write-Verbose "Is Last Block"
                $iterate = $false;
            }

        }
        catch {

            Write-Verbose "Failed API call $error" -Verbose

            $iterate = $false

        }

    }

    return $Users

}

<#
This script is a PowerShell function named "Add-UsersToJiraOrg". The function takes three parameters:

$BaseURL is a string that represents the base URL for the Jira instance.
$Users is an array of strings that represent the names of the users to be added to the Jira organization.
$OrgID is an integer that represents the ID of the Jira organization to which the users should be added.
The function starts by defining a variable $conURL that concatenates the $BaseURL and the endpoint for 
adding users to the Jira organization.

Next, the function uses a for loop to iterate over the elements of the $Users array. For each iteration, 
the function checks if the count of the remaining elements in the $Users array is greater than or equal 
to 50. If yes, it takes the next 50 elements and stores them in a hashtable $body with the key "usernames". 
If not, it takes the remaining elements and stores them in the $body hashtable.

The $body hashtable is then converted to a JSON string using the ConvertTo-Json cmdlet. The JSON string is 
then logged using the Write-Verbose cmdlet and converted back to a hashtable using the ConvertFrom-Json cmdlet.

Finally, the function uses the Invoke-RestMethod cmdlet to send a POST request to the $conURL endpoint with 
the $body JSON string as the request body and a header generated by calling the Get-Header function with the 
$UserName parameter.
#>
Function Add-UsersToJiraOrg {

    [CmdletBinding()]

    Param(
    
    [System.String] $BaseURL,
    [System.Array] $Users, 
    [System.Int32] $OrgID
    
    )
    
    $Users = $Users | Sort-Object -Unique
    $conURL = $BaseURL+'/rest/servicedeskapi/organization/'+$OrgID+'/user'
    $totalPushed = 0;

    Write-Verbose "Total Users: $($Users.Length) Users" -Verbose

    if(($Users.Length%50) -gt 0) {
    
        $length = [System.Math]::Ceiling(($Users.Length)/50)
    
    }

    else {
    
        $length = ($Users.Length)/50
    
    }

    for($i = 0; $i -lt $length; $i++){

        if($Users[($i*50)..(($Users.Length)-1)].count -ge 50){

            $chunk = $Users[($i*50)..((($i+1)*50)-1)]

            $body = @{

                'usernames' = $chunk
            
            } 

            Write-Verbose "Pushing $($chunk.length)" -Verbose

        }
        else {

            $chunk = $Users[($i*50)..(($Users.Length)-1)]

            $body = @{

                'usernames' = $chunk
            }

            Write-Verbose "Pushing $($chunk.Length)" -Verbose

        }
        
        $body = $body | ConvertTo-Json

        try {

            Invoke-RestMethod -Uri $conURL -Method Post -Headers $(Get-Header -UserName $UserName) -Body $body

            $totalPushed = $totalPushed + $chunk.Length

            Write-Verbose "Pushed $totalPushed of $($Users.Length)" -Verbose
        }
        catch {

            Write-Verbose "Failed to add users$($i*50) - $((($i+1)*50)-1)" -Verbose
            Write-Verbose $Error -Verbose

        }

    }

}

<#
Start-JiraSync takes in three parameters: $Url, $sourceorgs, and $targetOrgID.

The $Url parameter is a string that specifies the URL of the Jira instance that the function will be syncing with. 
The $sourceorgs parameter is an array of strings that represent the names of the source organizations whose users 
will be synced with the target Jira organization. The $targetOrgID parameter is an integer that represents the ID 
of the target Jira organization.

The function then calls the Get-AllUsersInParentGroup function, passing in the $Url and $sourceorgs parameters. This 
function retrieves all the users in the specified source organizations that are members of a specified parent group. 
The function also uses the -Verbose switch to provide detailed output.

If the $Users variable is empty, the function writes a verbose message indicating that the variable is empty and exits 
with an exit code of 1. Otherwise, the function calls the Add-UsersToJiraOrg function, passing in the $targetOrgID, 
$Url, and $Users parameters. This function adds the specified users to the target Jira organization.

Overall, this function is intended to synchronize the users in the specified source organizations with the target Jira 
organization.
#>
function Start-JiraSync {
    param (
        [System.String] $Url,
        [System.Array] $sourceorgs,
        [System.Int32] $targetOrgID
    )

    $Users = Get-AllUsersInParentGroup -BaseURL $Url -sourceorgs $sourceorgs -verbose

    if(-not $Users) {

        Write-Verbose "Empty `$Users Exiting..."
        
        Exit 1

    }

    else {

        Add-UsersToJiraOrg -OrgID $targetOrgID -BaseURL $Url -Users $Users

    }
    
}

<#
statement that checks if the $TargetOrgName variable is equal to the string 'ALL'. If it is, then the script loops through 
each key in the $groups hashtable using the ForEach-Object cmdlet. Within each iteration, the $sourceorgs and $targetOrgID 
variables are set based on the values stored in $groups using the current key and the $Prod variable. If either of these 
variables are empty, then a message is output using the Write-Verbose cmdlet. Otherwise, the Start-JiraSync function is 
called with the $Url, $sourceorgs, and $targetOrgID variables as parameters.

If $TargetOrgName is not equal to 'ALL', then the script sets the $sourceorgs and $targetOrgID variables using the $groups 
hashtable with the key equal to $TargetOrgName and the $Prod variable. If either of these variables are empty, then a message 
is output using the Write-Verbose cmdlet. Otherwise, the Start-JiraSync function is called with the $Url, $sourceorgs, and 
$targetOrgID variables as parameters.
#>

if($TargetOrgName -eq 'ALL') {

    $groups.keys | ForEach-Object {

        $sourceorgs = $groups[$_][1]
        $targetOrgID = $groups[$_][0][$Prod]

        if(-not $sourceorgs -or -not $targetOrgID) {

            Write-Verbose "Empty Variable recieved `$sourceorgs $sourceorgs, `$targetOrgID $targetOrgID" -Verbose

        }
        
        else {

            Start-JiraSync -Url $Url -sourceorgs $sourceorgs -targetOrgID $targetOrgID

        }

    }

}

else {

    $sourceorgs = $groups[$TargetOrgName][1]
    $targetOrgID = $groups[$TargetOrgName][0][$Prod]

    if(-not $sourceorgs -or -not $targetOrgID) {

        Write-Verbose "Empty Variable recieved `$sourceorgs $sourceorgs, `$targetOrgID $targetOrgID" -Verbose

    }
    
    else {

        Start-JiraSync -Url $Url -sourceorgs $sourceorgs -targetOrgID $targetOrgID

    }

}

##Use this line of code at the end of the script to disconnect from Azure
Disconnect-AzAccount -Verbose | Out-Null