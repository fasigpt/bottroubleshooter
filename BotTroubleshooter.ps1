param(
[parameter(Mandatory=$true)]
[string]
$subscriptionId,
$botServiceName

) #Must be the first statement in the script




Function DisplayMessage
{
    Param(
    [String]
    $Message,

    [parameter(Mandatory=$true)]
    [ValidateSet("Error","Warning","Info")]
    $Level
    )
    Process
    {
        if($Level -eq "Info"){
            Write-Host -BackgroundColor White -ForegroundColor Black $Message `n
            }
        if($Level -eq "Warning"){
        Write-Host -BackgroundColor Yellow -ForegroundColor Black $Message `n
        }
        if($Level -eq "Error"){
        Write-Host -BackgroundColor Red -ForegroundColor White $Message `n
        }
    }
}


function Get-UriSchemeAndAuthority
{
    param(
        [string]$InputString
    )

    $Uri = $InputString -as [uri]
    if($Uri){
               return  $Uri.Authority
    } else {
        throw "Malformed URI"
    }
}



#region Make sure to check for the presence of ArmClient here. If not, then install using choco install
    $chocoInstalled = Test-Path -Path "$env:ProgramData\Chocolatey"
    if (-not $chocoInstalled)
    {
        DisplayMessage -Message "Installing Chocolatey" -Level Info
        Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    }
    else
    {
        #Even if the folder is present, there are times when the directory is empty effectively meaning that choco is not installed. We have to initiate an install in this condition too
        if((Get-ChildItem "$env:ProgramData\Chocolatey" -Recurse | Measure-Object).Count -lt 20)
        {
            #There are less than 20 files in the choco directory so we are assuming that either choco is not installed or is not installed properly.
            DisplayMessage -Message "Installing Chocolatey. Please ensure that you have launched PowerShell as Administrator" -Level Info
            Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        }
    }

    $armClientInstalled = Test-Path -Path "$env:ProgramData\chocolatey\lib\ARMClient"

    if (-not $armClientInstalled)
    {
        DisplayMessage -Message "Installing ARMClient" -Level Info
        choco install armclient
    }
    else
    {
        #Even if the folder is present, there are times when the directory is empty effectively meaning that ARMClient is not installed. We have to initiate an install in this condition too
        if((Get-ChildItem "$env:ProgramData\chocolatey\lib\ARMClient" -Recurse | Measure-Object).Count -lt 5)
        {
            #There are less than 5 files in the choco directory so we are assuming that either choco is not installed or is not installed properly.
            DisplayMessage -Message "Installing ARMClient. Please ensure that you have launched PowerShell as Administrator" -Level Info
            choco install armclient
        }
    }


    <#
    NOTE: Please inspect all the powershell scripts prior to running any of these scripts to ensure safety.
    This is a community driven script library and uses your credentials to access resources on Azure and will have all the access to your Azure resources that you have.
    All of these scripts download and execute PowerShell scripts contributed by the community.
    We know it's safe, but you should verify the security and contents of any script from the internet you are not familiar with.
    #>

#endregion




#Do any work only if we are able to login into Azure. Ask to login only if the cached login user does not have token for the target subscription else it works as a single sign on
#armclient clearcache

if(@(ARMClient.exe listcache| Where-Object {$_.Contains($subscriptionId)}).Count -lt 1){
    ARMClient.exe login >$null
}

if(@(ARMClient.exe listcache | Where-Object {$_.Contains($subscriptionId)}).Count -lt 1){
    #Either the login attempt failed or this user does not have access to this subscriptionId. Stop the script
    DisplayMessage -Message ("Login Failed or You do not have access to subscription : " + $subscriptionId) -Level Error
    return
}
else
{
    DisplayMessage -Message ("User Logged in") -Level Info
}



#region Fetch Bot Service and backend endpoint Info

    DisplayMessage -Message "Fetching BotService and Endpoint information..." -Level Info
    
	#Fetch botService ResourceGroup and build the botserviceURI and get the AppID of botService
	$botservicesundersubidJSON = ARMClient.exe get /subscriptions/$subscriptionId/providers/Microsoft.BotService/botServices/?api-version=2017-12-01

    #Convert the string representation of JSON into PowerShell objects for easy 
	$botservicesundersubid = $botservicesundersubidJSON | ConvertFrom-Json
	
	 $botservicesundersubid.value.GetEnumerator() | foreach {       
		
        #$currSite = $_

        If($_.id.endswith("/Microsoft.BotService/botServices/$botServiceName"))
		{
		 
		 $botserviceUri = $_.id + "/?api-version=2017-12-01"
         $botserviceAppId= $_.properties.msaAppId
		 
		}
		
     }


    #Fetch the Bot Service Info and retrive the endpoint info
    $botserviceinfoJSON = ARMClient.exe get $botserviceUri
    #Convert the string representation of JSON into PowerShell objects for easy manipulation
    $botserviceinfo = $botserviceinfoJSON | ConvertFrom-Json    
    
    #Get the endpoint and retrive the web app name (without hostname)    		
    $botserviceendpoint=  $botserviceinfo.properties.endpoint 
    $hostedonazure = "false"
    $hostname= Get-UriSchemeAndAuthority $botserviceendpoint
    $webappname = ""

    DisplayMessage -Message "Validating if the endpoint is hosted on azure web app" -Level Info

    #validating if the URL of the endpoint is hosted on Azure web app
    if($hostname.contains("azurewebsites.net"))
    {
         $hostedonazure = "true"
         $webappname = $hostname.split('.')[0]
    }
    else
    {
        try{
        #we are doing nslookup since the URL can be custom host name
            $nslookupname =  resolve-dnsname $hostname -Type NS | Where-Object {$_.Namehost -like '*azurewebsites.net*'} | Select NameHost -ExpandProperty NameHost
            }
         catch {}

          if($nslookupname.contains("azurewebsites.net"))
             {
         $hostedonazure = "true"
         $webappname = $nslookupname.split('.')[0]
             }
    }

           
    
     #if the endpoint is hosted on azure web app then get all app settings to retrive the Appid and Password
     if( $hostedonazure -eq "true")
     {
                    
        #fetch the Endpoint Info (If only Hosted as Web App (*.Azurewebsites.net))
        $siteinfoJSON = ARMClient.exe get /subscriptions/$subscriptionId/providers/Microsoft.Web/sites/?api-version=2018-02-01
        #Convert the string representation of JSON into PowerShell objects for easy manipulation
        $sitesinfo = $siteinfoJSON | ConvertFrom-Json


     

     #Here all the sites are looped to get the right site name and its resoure group,
      $sitesinfo.value.GetEnumerator() | foreach {   
       
           If($_.id.endswith($webappname))
		    {
		 
		         $siteURL= $_.id + "/config/appsettings/list?api-version=2018-02-01"

            	 
		    }   

	    }

    try{
     DisplayMessage -Message "Getting the Bot Endpoints AppID and Password" -Level Info

        #fetch the endpoint web apps App Settings
         $endpointinfoJSON = ARMClient.exe POST $siteURL
        #Convert the string representation of JSON into PowerShell objects for easy manipulation
         $endpoint = $endpointinfoJSON | ConvertFrom-Json


	     $endpointAppid= $endpoint.properties.MicrosoftAppId
         $endpointPassword = $endpoint.properties.MicrosoftAppPassword
         }
    catch {}

}


#endregion 



#region Now the actual checks for Different Error Codes while calling Messaging endpoint

 DisplayMessage -Message "Validating the endpoint" -Level Info

$statuscode = 200
$errorstatus = "false"
$Message= "No Errors Found..."

try 
 {
     $response = Invoke-WebRequest -Uri  $botserviceendpoint
 } 

catch 
{
      $statuscode = $_.Exception.Response.StatusCode.value__

      if ( $_.Exception.Status -eq "NameResolutionFailure")
      {
         $statuscode = 502
      }
}


switch ( $statuscode)
{
 
 502
 {
   $errorstatus = "true"
   $Message = "Name resolution of the messaging endpoint ($botserviceendpoint) failed ( DNS resolution Failed). Please validate the messaging endpoint and re configure it."
 }

 405
 {
    $errorstatus = "false"
    $Message = "The messaging endpoint ($botserviceendpoint) seems to be valid"
 }

 200
 {
    $errorstatus = "true"
    $Message = "The hostName of the messaging endpoint ($botserviceendpoint) seems to be okay but the endpoint you have configured may be incorrect. validate if you are refering to right controller ex /api/messages"
 }

 404

 {
    $errorstatus = "true"
    $Message = "The hostName of the messaging endpoint ($botserviceendpoint) seems to be okay but the endpoint you have configured may be incorrect. validate if you are refering to right controller ex /api/messages"
 }

 403

 {
    $errorstatus = "true"
    $Message = "The messaging endpoint ($botserviceendpoint) seems to be not responding or in STOPPED state"
 }

 503

 {
    $errorstatus = "true"
    $Message = "The messaging endpoint ($botserviceendpoint) seems to be not responding or in STOPPED state"
 }

 500

 {
    $errorstatus = "true"
    $Message = "The messaging endpoint ($botserviceendpoint) seems to be failing with exception. Please review the exception call stack"
 }



}


#endregion 


#region Now validate the APPID and Password Between the endpoint and Bot Service

if($errorstatus -eq "true")
{

 #since there is a failure just report it and stop
 DisplayMessage -Message $Message -Level Error

}
else
{

 if( $hostedonazure -eq "true")
     {


      DisplayMessage -Message "Validating AppID and Password Mismatch between Bot Service and the Bot Endpoint" -Level Info
 #if no Errors found then validate AppID and Password

#validate passwords since AppIDs are same
 if($botserviceAppId -eq $endpointAppid)
 {
   #Since the AppIds match, validate the password.

         try
        {

        #fetch bearer token for given AppID refer https://docs.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-authentication?view=azure-bot-service-3.0 
        $password = [System.Web.HttpUtility]::UrlEncode($endpointPassword) 
        #$postParams = "grant_type=client_credentials&client_id=$endpointAppid&client_secret=$password&scope=808d16bf-311c-4936-a7a0-5dec691d2f5a%2F.default"        
		$postParams = "grant_type=client_credentials&client_id=$endpointAppid&client_secret=$password&scope=$botserviceAppId%2F.default"        
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add('Host','login.microsoftonline.com')
        $headers.Add('Content-Type','application/x-www-form-urlencoded')
        $responsejson = Invoke-WebRequest -Uri https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token -Method POST -Body $postParams -Headers $headers
        $response  = $responsejson | ConvertFrom-Json


        #Now call the actual endpoint to validate if it returned 401 or 200
        $postParams = "{'type': 'message'}"
        $headers2 = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers2.Add('Authorization','Bearer '+ $response.access_token)
        $headers2.Add('Content-Type','application/json')
        $responsejson = Invoke-WebRequest -Uri $botserviceendpoint -Method POST -Body $postParams -Headers $headers2
        $response  = $responsejson | ConvertFrom-Json
        $response

        }

        catch
        {
 
         $statuscode = $_.Exception.Response.StatusCode.value__
           
         if($statuscode -eq 401 )
          {
          DisplayMessage -Message ("The AppIDs match but Your bot might fail with 401 Authentication error as the password between Bot Service and your Web end point do not match. Please refer https://docs.microsoft.com/en-us/azure/bot-service/bot-service-manage-overview?view=azure-bot-service-3.0") -Level Error   
          }

        }

  


 }
 else
 {
  #Please ask them to sync App Id between the Messaging End Point and Bot Service
  DisplayMessage -Message "Your bot might fail with 401 Authentication error as the AppId between Bot Service and your Web end point do not match. Please refer https://docs.microsoft.com/en-us/azure/bot-service/bot-service-manage-overview?view=azure-bot-service-3.0" -Level Error

 }

 }

}


#endregion

#region Generate Output Report
DisplayMessage -Message ("Finished..If there are any errors reported above then fix them and please re run this script to validate other scenarios.") -Level Info
#endregion Generate Output Report

return
