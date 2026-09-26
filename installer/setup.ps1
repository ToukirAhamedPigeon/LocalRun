# LocalRun Setup - the installer wizard.
# installer\build.ps1 packs this script and payload.zip into LocalRun-Setup-<version>.exe;
# the exe extracts both to a temp folder and runs this script from there.
#
# Unattended install (terms are accepted by using -Quiet):
#   LocalRun-Setup-x.y.z.exe -Quiet [-InstallDir <dir>] [-DesktopDir '' to skip] [-StartMenuDir '' to skip]
param(
    [string]$InstallDir = '',
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
    [string]$StartMenuDir = (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'),
    [switch]$Quiet
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.IO.Compression.FileSystem

$AppId   = 'Pigeonic.LocalRun'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Pigeonic.LocalRun'
$Here    = $PSScriptRoot
$Stage   = Join-Path $Here 'payload'
$LogFile = Join-Path $env:TEMP 'LocalRun-Setup.log'

function Write-SetupLog($msg) {
    try { Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- native
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace LocalRunSetup {
    public static class Native {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid FormatId; public int PropertyId; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    // Stamps PKEY_AppUserModel_ID on a .lnk so the taskbar groups a pinned
    // shortcut with the running LocalRun window (which sets the same ID).
    public static class Shortcut {
        public static void SetAppId(string path, string appId) {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
            try {
                ((IPersistFile)link).Load(path, 2 /* STGM_READWRITE */);
                PropertyKey key; key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); key.PropertyId = 5;
                PropVariant value = new PropVariant();
                value.vt = 31; // VT_LPWSTR
                value.p = Marshal.StringToCoTaskMemUni(appId);
                try {
                    IPropertyStore store = (IPropertyStore)link;
                    Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                    Marshal.ThrowExceptionForHR(store.Commit());
                } finally { Marshal.FreeCoTaskMem(value.p); }
                ((IPersistFile)link).Save(path, true);
            } finally { Marshal.ReleaseComObject(link); }
        }
    }
}
'@

# ---------------------------------------------------------------- payload + existing install
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $Here 'payload.zip'), $Stage)
$Version = if ((Get-Content -LiteralPath (Join-Path $Stage 'LocalRun.ps1') -Raw) -match '\$AppVersion = ''([^'']+)''') { $Matches[1] } else { '' }

$Existing = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
if (-not $InstallDir) {
    $InstallDir = if ($Existing -and $Existing.InstallLocation) { $Existing.InstallLocation } else { Join-Path $env:LOCALAPPDATA 'Programs\LocalRun' }
}

# ---------------------------------------------------------------- install
function Test-AppRunning($dir) {
    $script = Join-Path $dir 'LocalRun.ps1'
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    return @($procs).Count -gt 0
}

function New-LocalRunShortcut($folder, $dir) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $path = Join-Path $folder 'LocalRun.lnk'
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $dir 'LocalRun.vbs') + '"'
    $lnk.WorkingDirectory = $dir
    $lnk.Description = 'Start local projects with one click'
    $lnk.IconLocation = (Join-Path $dir 'assets\localrun.ico') + ',0'
    $lnk.Save()
    [LocalRunSetup.Shortcut]::SetAppId($path, $AppId)
    return $path
}

# $report is called as: & $report <percent> <status text>
function Invoke-Install($dir, $desktop, $startMenu, [scriptblock]$report) {
    $ErrorActionPreference = 'Stop'
    & $report 5 'Checking for a running LocalRun...'
    if (Test-AppRunning $dir) { throw 'LocalRun is running from this folder. Close it, then try again.' }

    & $report 25 'Copying files...'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -Path (Join-Path $Stage '*') -Destination $dir -Recurse -Force

    & $report 55 'Creating shortcuts...'
    $made = @()
    if ($desktop)   { $made += New-LocalRunShortcut $desktop $dir }
    if ($startMenu) { $made += New-LocalRunShortcut $startMenu $dir }

    & $report 80 'Registering with Windows...'
    $sizeKb = [int]((Get-ChildItem -LiteralPath $dir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
    New-Item -Path $RegPath -Force | Out-Null
    $values = [ordered]@{
        DisplayName     = 'LocalRun'
        DisplayVersion  = $Version
        Publisher       = 'Pigeonic'
        DisplayIcon     = Join-Path $dir 'assets\localrun.ico'
        InstallLocation = $dir
        UninstallString = '"' + (Join-Path $env:WINDIR 'System32\wscript.exe') + '" "' + (Join-Path $dir 'Uninstall.vbs') + '"'
        URLInfoAbout    = 'https://pigeonic.com'
        InstallDate     = Get-Date -Format 'yyyyMMdd'
        Shortcuts       = $made -join '|'
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $RegPath -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $RegPath -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name EstimatedSize -Value $sizeKb -PropertyType DWord -Force | Out-Null

    & $report 100 'Done'
    Write-SetupLog "Installed LocalRun $Version to $dir; shortcuts: $($made -join ', ')"
}

if ($Quiet) {
    try {
        Invoke-Install $InstallDir $DesktopDir $StartMenuDir { param($pct, $text) }
        exit 0
    } catch {
        Write-SetupLog "Quiet install failed: $($_.Exception.Message)"
        exit 1
    }
}

[void][LocalRunSetup.Native]::SetCurrentProcessExplicitAppUserModelID('Pigeonic.LocalRun.Setup')

# ---------------------------------------------------------------- UI
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LocalRun Setup" Width="720" Height="520" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="NoResize" Background="#0E0C22" Foreground="#F4F1FF"
        FontFamily="Segoe UI" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="52" ResizeBorderThickness="0" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <LinearGradientBrush x:Key="Flame" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#FFB547" Offset="0"/>
      <GradientStop Color="#FF5E62" Offset="0.55"/>
      <GradientStop Color="#D63AF9" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="FlameBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Flame}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="110"/>
      <Setter Property="Padding" Value="20,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="11" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><ScaleTransform x:Name="S"/></Border.RenderTransform>
              <Border.Effect><DropShadowEffect Color="#FF5E62" BlurRadius="18" ShadowDepth="0" Opacity="0.35"/></Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="1.04" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="1.04" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.2"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Opacity" Value="0.35"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#E4E0FF"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="90"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="#16FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1" CornerRadius="11" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#2AFFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#B9B3E0"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#E81123"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E0FF"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="20" Height="20" CornerRadius="6" BorderThickness="1.5" BorderBrush="#55FFFFFF" Background="#10FFFFFF" VerticalAlignment="Center">
                <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="White"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#FF7A59"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Flame}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="Transparent"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Foreground" Value="#F4F1FF"/>
      <Setter Property="CaretBrush" Value="#FF9A3C"/>
      <Setter Property="SelectionBrush" Value="#FF5E62"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" Background="#14FFFFFF" BorderBrush="#2EFFFFFF" BorderThickness="1" CornerRadius="10">
              <ScrollViewer x:Name="PART_ContentHost" Margin="10,0" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#FF7A59"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Title" TargetType="TextBlock">
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="#B9B3E0"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
    </Style>
    <Style x:Key="Feature" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="#E4E0FF"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="12,0,0,0"/>
    </Style>
    <Style x:Key="FeatureIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Foreground" Value="#FF9A6B"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Width" Value="18"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#40FFFFFF" CornerRadius="4"/></ControlTemplate></Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid ClipToBounds="True">
    <Grid.RowDefinitions>
      <RowDefinition Height="52"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Ellipse Grid.RowSpan="3" Width="520" Height="520" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-260,-200,0" IsHitTestVisible="False">
      <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#45FF5E62" Offset="0"/><GradientStop Color="#00FF5E62" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
    </Ellipse>
    <Ellipse Grid.RowSpan="3" Width="480" Height="480" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="-220,0,0,-260" IsHitTestVisible="False">
      <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#3AB23AF2" Offset="0"/><GradientStop Color="#00B23AF2" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
    </Ellipse>

    <!-- title bar -->
    <Grid Grid.Row="0">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
        <Image x:Name="HeaderLogo" Width="24" Height="24" RenderOptions.BitmapScalingMode="HighQuality"/>
        <TextBlock Text="LocalRun Setup" FontSize="14" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <Border Background="#1FFFFFFF" CornerRadius="8" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="VersionText" FontSize="11" Foreground="#B9B3E0"/>
        </Border>
      </StackPanel>
      <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Content="&#xE8BB;" HorizontalAlignment="Right" VerticalAlignment="Top"/>
    </Grid>

    <!-- pages -->
    <Grid Grid.Row="1" Margin="40,8,40,0">

      <!-- 0: welcome -->
      <Grid x:Name="P0">
        <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
        <StackPanel VerticalAlignment="Center" Margin="0,0,0,20">
          <Grid x:Name="WelcomeArt" Width="78" Height="78" HorizontalAlignment="Left">
            <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
            <Grid.Effect><DropShadowEffect Color="#FF5E62" BlurRadius="36" ShadowDepth="0" Opacity="0.5"/></Grid.Effect>
            <Image x:Name="WelcomeLogo" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Grid>
          <TextBlock Margin="0,22,0,0" FontSize="28" FontWeight="SemiBold"><Run Text="Welcome to Local"/><Run Text="Run" Foreground="{StaticResource Flame}"/></TextBlock>
          <TextBlock x:Name="WelcomeSub" Style="{StaticResource Sub}"/>
          <StackPanel Margin="0,22,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource FeatureIcon}" Text="&#xE768;"/>
              <TextBlock Style="{StaticResource Feature}" Text="Start every local project and its dependencies with one click"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
              <TextBlock Style="{StaticResource FeatureIcon}" Text="&#xE8A9;"/>
              <TextBlock Style="{StaticResource Feature}" Text="All your project run commands in one place"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
              <TextBlock Style="{StaticResource FeatureIcon}" Text="&#xE72E;"/>
              <TextBlock Style="{StaticResource Feature}" Text="Your data stays on this PC. Nothing is sent anywhere."/>
            </StackPanel>
          </StackPanel>
          <Border x:Name="UpdateNote" Visibility="Collapsed" Margin="0,22,0,0" Padding="14,10" CornerRadius="10" Background="#1AFFB547" BorderBrush="#40FFB547" BorderThickness="1">
            <TextBlock x:Name="UpdateText" FontSize="13" Foreground="#FFD49A" TextWrapping="Wrap"/>
          </Border>
        </StackPanel>
      </Grid>

      <!-- 1: terms -->
      <Grid x:Name="P1" Visibility="Collapsed">
        <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Style="{StaticResource Title}" Text="License and Terms"/>
          <TextBlock Style="{StaticResource Sub}" Text="LocalRun is free, open-source software (MIT License). Please read the license and terms below and accept them to continue."/>
        </StackPanel>
        <Border Grid.Row="1" Margin="0,16,0,14" CornerRadius="12" Background="#12FFFFFF" BorderBrush="#22FFFFFF" BorderThickness="1">
          <ScrollViewer x:Name="TermsScroll" VerticalScrollBarVisibility="Auto" Margin="4" Padding="14,10,10,10">
            <TextBlock x:Name="TermsText" TextWrapping="Wrap" FontSize="12.5" Foreground="#CFCAF0" LineHeight="19"/>
          </ScrollViewer>
        </Border>
        <CheckBox x:Name="AcceptBox" Grid.Row="2" Style="{StaticResource Check}" Content="I have read and accept the license and terms"/>
      </Grid>

      <!-- 2: options -->
      <Grid x:Name="P2" Visibility="Collapsed">
        <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
        <StackPanel>
          <TextBlock Style="{StaticResource Title}" Text="Install options"/>
          <TextBlock Style="{StaticResource Sub}" Text="Choose where to install LocalRun and which shortcuts to create."/>
          <TextBlock Text="INSTALL FOLDER" FontSize="11" FontWeight="SemiBold" Foreground="#8F89B8" Margin="0,26,0,7"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="TxtDir" Style="{StaticResource Field}"/>
            <Button x:Name="BtnBrowse" Grid.Column="1" Style="{StaticResource GhostBtn}" Height="40" Margin="8,0,0,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="Browse" Margin="8,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </Grid>
          <TextBlock x:Name="DirError" Foreground="#FF8FA3" FontSize="12.5" Margin="0,8,0,0" Visibility="Collapsed" TextWrapping="Wrap"/>
          <CheckBox x:Name="ChkDesktop" Style="{StaticResource Check}" Content="Create a desktop shortcut" IsChecked="True" Margin="0,22,0,0"/>
          <CheckBox x:Name="ChkStart" Style="{StaticResource Check}" Content="Add LocalRun to the Start menu" IsChecked="True" Margin="0,12,0,0"/>
          <Border Margin="0,24,0,0" Padding="14,10" CornerRadius="10" Background="#10FFFFFF">
            <TextBlock FontSize="12.5" Foreground="#9D97C4" TextWrapping="Wrap"
                       Text="Setup will copy LocalRun into this folder, create the shortcuts you tick, and add LocalRun to Settings &gt; Apps so you can uninstall it there. Nothing else is changed, and no administrator rights are needed. Your saved projects live separately in %APPDATA%\LocalRun and survive updates and reinstalls."/>
          </Border>
        </StackPanel>
      </Grid>

      <!-- 3: progress -->
      <Grid x:Name="P3" Visibility="Collapsed">
        <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
        <StackPanel VerticalAlignment="Center" Margin="0,0,0,30">
          <TextBlock Style="{StaticResource Title}" Text="Installing LocalRun"/>
          <TextBlock x:Name="ProgText" Style="{StaticResource Sub}" Text="Preparing..."/>
          <Border x:Name="ProgTrack" Height="10" CornerRadius="5" Background="#22FFFFFF" Margin="0,26,0,0">
            <Border x:Name="ProgFill" HorizontalAlignment="Left" Width="0" CornerRadius="5" Background="{StaticResource Flame}">
              <Border.Effect><DropShadowEffect Color="#FF5E62" BlurRadius="14" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
            </Border>
          </Border>
          <TextBlock x:Name="ProgPct" Text="0%" FontSize="12" Foreground="#8F89B8" Margin="0,8,0,0" HorizontalAlignment="Right"/>
        </StackPanel>
      </Grid>

      <!-- 4: done -->
      <Grid x:Name="P4" Visibility="Collapsed">
        <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
        <StackPanel VerticalAlignment="Center" Margin="0,0,0,30">
          <Border x:Name="DoneBadge" Width="72" Height="72" CornerRadius="36" HorizontalAlignment="Left" Background="{StaticResource Flame}" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><ScaleTransform/></Border.RenderTransform>
            <Border.Effect><DropShadowEffect x:Name="DoneGlow" Color="#FF5E62" BlurRadius="36" ShadowDepth="0" Opacity="0.55"/></Border.Effect>
            <TextBlock x:Name="DoneGlyph" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="30" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="DoneTitle" Style="{StaticResource Title}" Margin="0,22,0,0" Text="LocalRun is installed"/>
          <TextBlock x:Name="DoneText" Style="{StaticResource Sub}"/>
          <CheckBox x:Name="ChkLaunch" Style="{StaticResource Check}" Content="Launch LocalRun now" IsChecked="True" Margin="0,24,0,0"/>
        </StackPanel>
      </Grid>
    </Grid>

    <!-- footer -->
    <Border Grid.Row="2" BorderBrush="#1AFFFFFF" BorderThickness="0,1,0,0" Padding="40,16,24,18" Margin="0,16,0,0">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <StackPanel x:Name="Dots" Orientation="Horizontal" VerticalAlignment="Center"/>
          <TextBlock x:Name="StepText" FontSize="12" Foreground="#8F89B8" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnBack" Style="{StaticResource GhostBtn}" Content="Back"/>
          <Button x:Name="BtnNext" Style="{StaticResource FlameBtn}" Content="Next" Margin="10,0,0,0"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($Xaml)
foreach ($n in 'HeaderLogo','VersionText','BtnClose','P0','P1','P2','P3','P4','WelcomeArt','WelcomeLogo','WelcomeSub',
               'UpdateNote','UpdateText','TermsScroll','TermsText','AcceptBox','TxtDir','BtnBrowse','DirError','ChkDesktop',
               'ChkStart','ProgText','ProgTrack','ProgFill','ProgPct','DoneBadge','DoneGlyph','DoneTitle','DoneText',
               'ChkLaunch','Dots','StepText','BtnBack','BtnNext') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}
$Pages = @($P0, $P1, $P2, $P3, $P4)
$StepNames = @('Welcome', 'License and Terms', 'Install options', 'Installing', 'Finished')

$P_Opacity = [System.Windows.UIElement]::OpacityProperty
$P_X       = [System.Windows.Media.TranslateTransform]::XProperty
$P_Y       = [System.Windows.Media.TranslateTransform]::YProperty
$P_SX      = [System.Windows.Media.ScaleTransform]::ScaleXProperty
$P_SY      = [System.Windows.Media.ScaleTransform]::ScaleYProperty
$P_Width   = [System.Windows.FrameworkElement]::WidthProperty
$EaseOut   = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }
$EaseBack  = New-Object System.Windows.Media.Animation.BackEase  -Property @{ EasingMode = 'EaseOut'; Amplitude = 0.4 }
$EaseSine  = New-Object System.Windows.Media.Animation.SineEase  -Property @{ EasingMode = 'EaseInOut' }

function Animate($Target, $Property, [double]$To, [double]$Ms, $From = $null, $Ease = $null, [switch]$Forever) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $To
    if ($null -ne $From) { $a.From = [double]$From }
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
    if ($Ease) { $a.EasingFunction = $Ease }
    if ($Forever) { $a.AutoReverse = $true; $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
    $Target.BeginAnimation($Property, $a)
}

function Pump($ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    do {
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})
        Start-Sleep -Milliseconds 15
    } while ((Get-Date) -lt $end)
}

function Get-Brush($hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }

# ---------------------------------------------------------------- content
$icoPath = Join-Path $Stage 'assets\localrun.ico'
$pngPath = Join-Path $Stage 'assets\logo.png'
try {
    $logo = New-Object System.Windows.Media.Imaging.BitmapImage
    $logo.BeginInit(); $logo.UriSource = New-Object System.Uri $pngPath; $logo.CacheOption = 'OnLoad'; $logo.EndInit()
    $HeaderLogo.Source = $logo
    $WelcomeLogo.Source = $logo
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $icoPath))
} catch {}

$VersionText.Text = "v$Version"
$WelcomeSub.Text = "This will install LocalRun $Version on this computer."
if ($Existing -and $Existing.DisplayVersion) {
    $UpdateNote.Visibility = 'Visible'
    $UpdateText.Text = "LocalRun $($Existing.DisplayVersion) is already installed. Setup will update it to $Version. Your saved projects are kept."
}

# Terms: plain text, first line is the title.
$terms = [System.IO.File]::ReadAllText((Join-Path $Stage 'TERMS.md'), [System.Text.Encoding]::UTF8).Trim() -split "\r?\n"
$TermsText.Inlines.Clear()
for ($i = 0; $i -lt $terms.Count; $i++) {
    $line = $terms[$i]
    $run = New-Object System.Windows.Documents.Run ($line)
    if ($i -eq 0 -or $line -match '^\d+\.\s') {
        $run.FontWeight = 'SemiBold'
        $run.Foreground = Get-Brush '#F4F1FF'
        if ($i -eq 0) { $run.FontSize = 15 }
    }
    $TermsText.Inlines.Add($run)
    if ($i -lt $terms.Count - 1) { $TermsText.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
}

$TxtDir.Text = $InstallDir
$ChkDesktop.IsChecked = [bool]$DesktopDir
$ChkStart.IsChecked = [bool]$StartMenuDir

# step dots
$DotEls = @()
for ($i = 0; $i -lt 5; $i++) {
    $d = New-Object System.Windows.Controls.Border
    $d.Height = 6; $d.Width = 6; $d.CornerRadius = New-Object System.Windows.CornerRadius 3
    $d.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
    $d.Background = Get-Brush '#33FFFFFF'
    [void]$Dots.Children.Add($d)
    $DotEls += $d
}

# ---------------------------------------------------------------- navigation
$script:Page = 0
$script:Installed = $false

function Update-Nav {
    $p = $script:Page
    for ($i = 0; $i -lt 5; $i++) {
        $DotEls[$i].Background = if ($i -eq $p) { $window.FindResource('Flame') } elseif ($i -lt $p) { Get-Brush '#88FF7A59' } else { Get-Brush '#33FFFFFF' }
        Animate $DotEls[$i] $P_Width $(if ($i -eq $p) { 22 } else { 6 }) 220 -Ease $EaseOut
    }
    $StepText.Text = "Step $($p + 1) of 5  -  $($StepNames[$p])"
    $BtnBack.Visibility = if ($p -in 1, 2) { 'Visible' } else { 'Collapsed' }
    $BtnNext.Visibility = if ($p -eq 3) { 'Collapsed' } else { 'Visible' }
    $BtnNext.Content = switch ($p) { 2 { 'Install' } 4 { if ($script:Installed) { 'Finish' } else { 'Close' } } default { 'Next' } }
    $BtnNext.IsEnabled = ($p -ne 1) -or [bool]$AcceptBox.IsChecked
}

function Show-Page($i, [switch]$Backward) {
    for ($k = 0; $k -lt $Pages.Count; $k++) { if ($k -ne $i) { $Pages[$k].Visibility = 'Collapsed' } }
    $page = $Pages[$i]
    $page.Visibility = 'Visible'
    Animate $page $P_Opacity 1 260 -From 0
    Animate $page.RenderTransform $P_X 0 360 -From $(if ($Backward) { -28 } else { 28 }) -Ease $EaseOut
    $script:Page = $i
    Update-Nav
}

function Set-Progress($pct, $text) {
    $ProgText.Text = $text
    $ProgPct.Text = "$pct%"
    Animate $ProgFill $P_Width ($ProgTrack.ActualWidth * $pct / 100) 300 -Ease $EaseOut
}

function Show-Done([bool]$ok, $message) {
    $script:Installed = $ok
    if ($ok) {
        $DoneBadge.Background = $window.FindResource('Flame')
        $DoneGlyph.Text = [string][char]0xE73E
        $DoneTitle.Text = 'LocalRun is installed'
        $DoneText.Text = $message
        $ChkLaunch.Visibility = 'Visible'
    } else {
        $DoneBadge.Background = Get-Brush '#E8445F'
        $DoneGlyph.Text = [string][char]0xE711
        $DoneTitle.Text = 'Installation did not finish'
        $DoneText.Text = "$message`n`nNothing else was changed. Close Setup, or go back and try again."
        $ChkLaunch.Visibility = 'Collapsed'
    }
    Show-Page 4
    $BtnBack.Visibility = if ($ok) { 'Collapsed' } else { 'Visible' }
    Animate $DoneBadge.RenderTransform $P_SX 1 520 -From 0.3 -Ease $EaseBack
    Animate $DoneBadge.RenderTransform $P_SY 1 520 -From 0.3 -Ease $EaseBack
}

function Start-Install {
    $dir = $TxtDir.Text.Trim().Trim('"').TrimEnd('\')
    if (-not $dir -or -not [System.IO.Path]::IsPathRooted($dir) -or $dir.Length -le 3) {
        $DirError.Text = 'Choose a full folder path, for example C:\Users\you\AppData\Local\Programs\LocalRun.'
        $DirError.Visibility = 'Visible'
        return
    }
    $DirError.Visibility = 'Collapsed'
    $desk = if ($ChkDesktop.IsChecked) { if ($DesktopDir) { $DesktopDir } else { [Environment]::GetFolderPath('Desktop') } } else { '' }
    $menu = if ($ChkStart.IsChecked) { if ($StartMenuDir) { $StartMenuDir } else { Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs' } } else { '' }
    $script:TargetDir = $dir

    Show-Page 3
    Pump 350
    $report = { param($pct, $text) Set-Progress $pct $text; Pump 380 }
    try {
        Invoke-Install $dir $desk $menu $report
        Pump 250
        Show-Done $true "LocalRun $Version was installed to $dir."
    } catch {
        Write-SetupLog "Install failed: $($_.Exception.Message)"
        Show-Done $false $_.Exception.Message
    }
}

$AcceptBox.Add_Click({ Update-Nav })

$BtnNext.Add_Click({
    switch ($script:Page) {
        0 { Show-Page 1 }
        1 { if ($AcceptBox.IsChecked) { Show-Page 2 } }
        2 { Start-Install }
        4 {
            if ($script:Installed -and $ChkLaunch.IsChecked) {
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $script:TargetDir 'LocalRun.vbs') + '"')
            }
            $window.Close()
        }
    }
})

$BtnBack.Add_Click({
    if ($script:Page -eq 4) { Show-Page 2 -Backward }
    elseif ($script:Page -gt 0) { Show-Page ($script:Page - 1) -Backward }
})

$BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder to install LocalRun into'
    $dlg.ShowNewFolderButton = $true
    $parent = Split-Path -Parent $TxtDir.Text
    if ($parent -and (Test-Path -LiteralPath $parent)) { $dlg.SelectedPath = $parent }
    if ($dlg.ShowDialog() -eq 'OK') {
        $picked = $dlg.SelectedPath
        # Installing straight into an existing folder is allowed, but a named subfolder is tidier.
        $TxtDir.Text = if ((Split-Path -Leaf $picked) -eq 'LocalRun') { $picked } else { Join-Path $picked 'LocalRun' }
    }
})

$BtnClose.Add_Click({
    if ($script:Page -eq 3) { return }
    if ($script:Page -eq 4) { $window.Close(); return }
    $ans = [System.Windows.MessageBox]::Show('Cancel LocalRun setup? Nothing has been installed yet.', 'LocalRun Setup', 'YesNo', 'Question')
    if ($ans -eq 'Yes') { $window.Close() }
})

$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return' -and $BtnNext.IsEnabled -and $BtnNext.Visibility -eq 'Visible' -and $script:Page -ne 3) {
        $BtnNext.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    }
})

$window.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        $round = 2
        [void][LocalRunSetup.Native]::DwmSetWindowAttribute($h, 33, [ref]$round, 4)
        $border = 0x0054262B
        [void][LocalRunSetup.Native]::DwmSetWindowAttribute($h, 34, [ref]$border, 4)
    } catch {}
})

$window.Add_Loaded({
    Animate $WelcomeArt.RenderTransform $P_Y -8 1600 -Ease $EaseSine -Forever
    Show-Page 0
})

Write-SetupLog "Setup $Version started from $Here"
[void]$window.ShowDialog()
