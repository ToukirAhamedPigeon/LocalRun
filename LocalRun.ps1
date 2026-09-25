# LocalRun - start every local project's run command with one click.
# Project list is stored per machine in %APPDATA%\LocalRun\projects.json,
# so this folder can be copied to another PC and keep its own list there.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$AppDir     = $PSScriptRoot
$LogoPath   = Join-Path $AppDir 'assets\logo.png'
$ConfigDir  = Join-Path $env:APPDATA 'LocalRun'
$ConfigFile = Join-Path $ConfigDir 'projects.json'
$LegacyFile = Join-Path $env:APPDATA 'LocalhostLauncher\projects.json'

$script:Projects    = New-Object System.Collections.ArrayList
$script:Running     = @{}   # project Id -> launched console process
$script:Cards       = @{}   # project Id -> hashtable of card elements
$script:EditingId   = $null
$script:DeletingId  = $null
$script:AllowMissing = $false
$script:OverlayOpen = $false

try {
    Add-Type -Namespace LocalRun -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
} catch {}

# ---------------------------------------------------------------- XAML
$WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LocalRun" Width="1010" Height="680" MinWidth="700" MinHeight="480"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0E0C22" Foreground="#F4F1FF" FontFamily="Segoe UI" AllowDrop="True"
        UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="56" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
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
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="11"
                    Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
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
                      <DoubleAnimation Storyboard.TargetName="B" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0.85" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.2"/>
                      <DoubleAnimation Storyboard.TargetName="S" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.2"/>
                      <DoubleAnimation Storyboard.TargetName="B" Storyboard.TargetProperty="(UIElement.Effect).(DropShadowEffect.Opacity)" To="0.35" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Opacity" Value="0.82"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource FlameBtn}">
      <Setter Property="Background" Value="#E8445F"/>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#E4E0FF"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Height" Value="38"/>
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
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#3AFFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#B9B3E0"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="#12FFFFFF" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#28FFFFFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerIconBtn" TargetType="Button" BasedOn="{StaticResource IconBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="#12FFFFFF" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#38FF4D6D"/>
                <Setter Property="Foreground" Value="#FF8FA3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CaptionBtn" TargetType="Button">
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
            <Border x:Name="B" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#1FFFFFFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource CaptionBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
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

    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Foreground" Value="#F4F1FF"/>
      <Setter Property="CaretBrush" Value="#FF9A3C"/>
      <Setter Property="SelectionBrush" Value="#FF5E62"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" Background="#14FFFFFF" BorderBrush="#2EFFFFFF" BorderThickness="1" CornerRadius="10">
              <ScrollViewer x:Name="PART_ContentHost" Margin="10,0" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="#FF7A59"/>
                <Setter TargetName="B" Property="Background" Value="#1CFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#8F89B8"/>
      <Setter Property="Margin" Value="0,0,0,7"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="#33FFFFFF" CornerRadius="4"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root" ClipToBounds="True">
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- slow-moving colour glows behind everything -->
    <Grid Grid.RowSpan="3" IsHitTestVisible="False">
      <Ellipse x:Name="Blob1" Width="640" Height="640" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-300,-200,0">
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#50FF5E62" Offset="0"/><GradientStop Color="#00FF5E62" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Blob2" Width="600" Height="600" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="-240,0,0,-280">
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#45B23AF2" Offset="0"/><GradientStop Color="#00B23AF2" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Blob3" Width="420" Height="420" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="260,0,0,-260">
        <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#30FFB547" Offset="0"/><GradientStop Color="#00FFB547" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
        <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
      </Ellipse>
    </Grid>

    <!-- title bar -->
    <Grid Grid.Row="0">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
        <Grid Width="30" Height="30">
          <Border x:Name="HeaderLogoFallback" CornerRadius="9" Background="{StaticResource Flame}">
            <TextBlock Text="L" FontWeight="Bold" FontSize="16" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Image x:Name="HeaderLogo" RenderOptions.BitmapScalingMode="HighQuality"/>
        </Grid>
        <TextBlock Text="Local" FontSize="19" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <TextBlock Text="Run" FontSize="19" FontWeight="Bold" Foreground="{StaticResource Flame}" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
        <Button x:Name="BtnMin" Style="{StaticResource CaptionBtn}" Content="&#xE921;"/>
        <Button x:Name="BtnMax" Style="{StaticResource CaptionBtn}" Content="&#xE922;"/>
        <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Content="&#xE8BB;"/>
      </StackPanel>
    </Grid>

    <!-- heading + add -->
    <Grid Grid.Row="1" Margin="30,6,30,22">
      <StackPanel>
        <TextBlock Text="Your projects" FontSize="28" FontWeight="SemiBold"/>
        <TextBlock x:Name="CountText" FontSize="13" Foreground="#8F89B8" Margin="0,4,0,0"/>
      </StackPanel>
      <Button x:Name="BtnNew" Style="{StaticResource FlameBtn}" HorizontalAlignment="Right" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE710;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center"/>
          <TextBlock Text="New project" Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
    </Grid>

    <!-- project cards -->
    <ScrollViewer x:Name="Scroller" Grid.Row="2" Margin="30,0,12,16" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <WrapPanel x:Name="CardList" Margin="0,4,0,0"/>
    </ScrollViewer>

    <!-- empty state -->
    <StackPanel x:Name="EmptyState" Grid.Row="2" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,60" Visibility="Collapsed">
      <Grid x:Name="EmptyArt" Width="104" Height="104" HorizontalAlignment="Center">
        <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
        <Grid.Effect><DropShadowEffect Color="#FF5E62" BlurRadius="40" ShadowDepth="0" Opacity="0.55"/></Grid.Effect>
        <Border x:Name="EmptyLogoFallback" CornerRadius="28" Background="{StaticResource Flame}">
          <TextBlock Text="L" FontWeight="Bold" FontSize="52" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <Image x:Name="EmptyLogo" RenderOptions.BitmapScalingMode="HighQuality"/>
      </Grid>
      <TextBlock Text="No projects yet" FontSize="22" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,26,0,0"/>
      <TextBlock Text="Add the .bat, .cmd or .ps1 that starts a project,&#xA;then launch it with one click." TextAlignment="Center"
                 Foreground="#8F89B8" FontSize="14" Margin="0,8,0,22" HorizontalAlignment="Center"/>
      <Button x:Name="BtnEmptyAdd" Style="{StaticResource FlameBtn}" HorizontalAlignment="Center" Content="Add your first project"/>
      <TextBlock Text="Tip: you can also drop a command file onto this window." FontSize="12" Foreground="#6E6A8F" HorizontalAlignment="Center" Margin="0,16,0,0"/>
    </StackPanel>

    <!-- drag and drop hint -->
    <Border x:Name="DropHint" Grid.Row="1" Grid.RowSpan="2" Margin="24,0,24,24" CornerRadius="20" BorderThickness="2"
            BorderBrush="{StaticResource Flame}" Background="#E00E0C22" Visibility="Collapsed" IsHitTestVisible="False">
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
        <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="#FF7A59" HorizontalAlignment="Center"/>
        <TextBlock Text="Drop the command file to add it" FontSize="18" FontWeight="SemiBold" Margin="0,14,0,0" HorizontalAlignment="Center"/>
      </StackPanel>
    </Border>

    <!-- dialogs -->
    <Grid x:Name="Overlay" Grid.RowSpan="3" Background="#CC07061A" Visibility="Collapsed" Opacity="0">
      <Border x:Name="Dialog" Width="540" Background="#1A1636" CornerRadius="20" Padding="30,28" BorderBrush="#30FFFFFF" BorderThickness="1"
              HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
        <Border.RenderTransform><ScaleTransform ScaleX="0.94" ScaleY="0.94"/></Border.RenderTransform>
        <Border.Effect><DropShadowEffect BlurRadius="50" ShadowDepth="0" Opacity="0.6" Color="#000000"/></Border.Effect>
        <Grid>
          <StackPanel x:Name="EditPanel">
            <TextBlock x:Name="DialogTitle" Text="New project" FontSize="21" FontWeight="SemiBold"/>
            <TextBlock Text="Point LocalRun at the .bat, .cmd or .ps1 that starts this project." Foreground="#8F89B8" FontSize="13" Margin="0,5,0,22" TextWrapping="Wrap"/>
            <TextBlock Text="PROJECT TITLE" Style="{StaticResource FieldLabel}"/>
            <TextBox x:Name="TxtTitle" Style="{StaticResource Field}"/>
            <TextBlock Text="COMMAND FILE" Style="{StaticResource FieldLabel}" Margin="0,16,0,7"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="TxtPath" Style="{StaticResource Field}" FontFamily="Cascadia Mono, Consolas" FontSize="13"/>
              <Button x:Name="BtnBrowse" Grid.Column="1" Style="{StaticResource GhostBtn}" Height="40" Margin="8,0,0,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center"/>
                  <TextBlock Text="Browse" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
            </Grid>
            <TextBlock x:Name="DialogError" Foreground="#FF8FA3" FontSize="13" Margin="0,12,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,26,0,0">
              <Button x:Name="BtnCancel" Style="{StaticResource GhostBtn}" Content="Cancel"/>
              <Button x:Name="BtnSave" Style="{StaticResource FlameBtn}" Content="Add project" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>

          <StackPanel x:Name="ConfirmPanel" Visibility="Collapsed">
            <TextBlock Text="Remove this project?" FontSize="21" FontWeight="SemiBold"/>
            <TextBlock x:Name="ConfirmText" Foreground="#B9B3E0" FontSize="14" Margin="0,10,0,0" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,26,0,0">
              <Button x:Name="BtnConfirmNo" Style="{StaticResource GhostBtn}" Content="Keep it"/>
              <Button x:Name="BtnConfirmYes" Style="{StaticResource DangerBtn}" Content="Remove" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- toast -->
    <Border x:Name="Toast" Grid.RowSpan="3" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,26"
            Padding="16,11" CornerRadius="12" Background="#F2221D45" BorderBrush="#33FFFFFF" BorderThickness="1"
            Opacity="0" IsHitTestVisible="False">
      <Border.RenderTransform><TranslateTransform Y="20"/></Border.RenderTransform>
      <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="0" Opacity="0.5" Color="#000000"/></Border.Effect>
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="ToastDot" Width="8" Height="8" Fill="#3DDC97" VerticalAlignment="Center"/>
        <TextBlock x:Name="ToastText" Margin="10,0,0,0" FontSize="13"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$CardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="300" Height="178" Margin="0,0,18,18" CornerRadius="18" Padding="18,16"
        Background="#171433" BorderBrush="#2B2654" BorderThickness="1" RenderTransformOrigin="0.5,0.5" Opacity="0">
  <Border.RenderTransform>
    <TransformGroup><ScaleTransform/><TranslateTransform Y="18"/></TransformGroup>
  </Border.RenderTransform>
  <Border.Effect><DropShadowEffect Color="#FF5E62" BlurRadius="30" ShadowDepth="0" Opacity="0"/></Border.Effect>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border x:Name="Tile" Width="42" Height="42" CornerRadius="12">
        <TextBlock x:Name="Initial" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="TitleText" FontSize="16" FontWeight="SemiBold" Foreground="#F4F1FF" TextTrimming="CharacterEllipsis"/>
        <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
          <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#6E6A8F" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusText" Margin="6,0,0,0" FontSize="12" Foreground="#8F89B8" Text="Ready"/>
        </StackPanel>
      </StackPanel>
    </Grid>
    <StackPanel Grid.Row="1" Margin="0,14,0,0">
      <TextBlock x:Name="FileText" FontSize="12.5" Foreground="#C9C3F0" FontFamily="Cascadia Mono, Consolas" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="DirText" FontSize="11.5" Foreground="#7D77A6" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Button x:Name="RunBtn" Style="{DynamicResource FlameBtn}" Height="36">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="RunGlyph" Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center"/>
          <TextBlock x:Name="RunText" Text="Run" Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
      <Button x:Name="EditBtn" Grid.Column="1" Style="{DynamicResource IconBtn}" Content="&#xE70F;" Margin="8,0,0,0" ToolTip="Edit"/>
      <Button x:Name="DelBtn" Grid.Column="2" Style="{DynamicResource DangerIconBtn}" Content="&#xE74D;" Margin="8,0,0,0" ToolTip="Remove"/>
    </Grid>
  </Grid>
</Border>
'@

# ---------------------------------------------------------------- helpers
$P_Opacity   = [System.Windows.UIElement]::OpacityProperty
$P_SX        = [System.Windows.Media.ScaleTransform]::ScaleXProperty
$P_SY        = [System.Windows.Media.ScaleTransform]::ScaleYProperty
$P_X         = [System.Windows.Media.TranslateTransform]::XProperty
$P_Y         = [System.Windows.Media.TranslateTransform]::YProperty
$P_FxOpacity = [System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty
$P_Bg        = [System.Windows.Controls.Control]::BackgroundProperty
$P_Fg        = [System.Windows.Controls.Control]::ForegroundProperty

$EaseOut  = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }
$EaseBack = New-Object System.Windows.Media.Animation.BackEase  -Property @{ EasingMode = 'EaseOut'; Amplitude = 0.35 }
$EaseSine = New-Object System.Windows.Media.Animation.SineEase  -Property @{ EasingMode = 'EaseInOut' }

$TilePalette = @(
    @('#FFB547', '#FF5E62'), @('#FF7A59', '#E0339C'), @('#FF5E8A', '#B23AF2'),
    @('#FF9A3C', '#FF4F7B'), @('#F857A6', '#7B3AF5'), @('#FFC857', '#F2552C')
)

function Get-Color($hex) { [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
function Get-Brush($hex) { New-Object System.Windows.Media.SolidColorBrush (Get-Color $hex) }

function Animate {
    param($Target, $Property, [double]$To, [double]$Ms, $From = $null, [double]$Delay = 0,
          $Ease = $null, [switch]$Forever, [switch]$Reverse, [scriptblock]$OnDone)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $To
    if ($null -ne $From) { $a.From = [double]$From }
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
    $a.BeginTime = [TimeSpan]::FromMilliseconds($Delay)
    if ($Ease) { $a.EasingFunction = $Ease }
    if ($Reverse) { $a.AutoReverse = $true }
    if ($Forever) { $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
    if ($OnDone) { $a.Add_Completed($OnDone) }
    $Target.BeginAnimation($Property, $a)
}

function Stop-Animation($Target, $Property, $Value) {
    $Target.BeginAnimation($Property, $null)
    $Target.SetValue($Property, [double]$Value)
}

# ---------------------------------------------------------------- data
function Load-Projects {
    $script:Projects.Clear()
    $file = $ConfigFile
    $migrating = $false
    if (-not (Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath $LegacyFile)) { $file = $LegacyFile; $migrating = $true }
    if (-not (Test-Path -LiteralPath $file)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return }
        foreach ($p in (ConvertFrom-Json $raw)) {
            $id = if ($p.Id) { [string]$p.Id } else { [guid]::NewGuid().ToString('N') }
            [void]$script:Projects.Add([pscustomobject]@{ Id = $id; Title = [string]$p.Title; Path = [string]$p.Path })
        }
        if ($migrating) { Save-Projects }
    } catch {
        [System.Windows.MessageBox]::Show("Could not read the project list:`n$file`n`n$($_.Exception.Message)", 'LocalRun') | Out-Null
    }
}

function Save-Projects {
    if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
    $arr = @($script:Projects | ForEach-Object { [ordered]@{ Id = $_.Id; Title = $_.Title; Path = $_.Path } })
    $json = if ($arr.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $arr -Depth 3 }
    [System.IO.File]::WriteAllText($ConfigFile, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Project($id) {
    foreach ($p in $script:Projects) { if ($p.Id -eq $id) { return $p } }
    return $null
}

function Test-ProjectFile($p) {
    return [bool]($p.Path -and (Test-Path -LiteralPath $p.Path -PathType Leaf))
}

# ---------------------------------------------------------------- window
$window = [System.Windows.Markup.XamlReader]::Parse($WindowXaml)
foreach ($n in 'Root','Blob1','Blob2','Blob3','HeaderLogo','HeaderLogoFallback','BtnMin','BtnMax','BtnClose',
               'CountText','BtnNew','Scroller','CardList','EmptyState','EmptyArt','EmptyLogo','EmptyLogoFallback',
               'BtnEmptyAdd','DropHint','Overlay','Dialog','EditPanel','DialogTitle','TxtTitle','TxtPath','BtnBrowse',
               'DialogError','BtnCancel','BtnSave','ConfirmPanel','ConfirmText','BtnConfirmNo','BtnConfirmYes',
               'Toast','ToastDot','ToastText') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}
$FlameBrush = $window.FindResource('Flame')

if (Test-Path -LiteralPath $LogoPath) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri $LogoPath
        $bmp.CacheOption = 'OnLoad'
        $bmp.EndInit()
        $HeaderLogo.Source = $bmp
        $EmptyLogo.Source = $bmp
        $HeaderLogoFallback.Visibility = 'Collapsed'
        $EmptyLogoFallback.Visibility = 'Collapsed'
        $window.Icon = $bmp
    } catch {}
}

# ---------------------------------------------------------------- toast
$script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds(2600)
$script:ToastTimer.Add_Tick({
    $script:ToastTimer.Stop()
    Animate $Toast $P_Opacity 0 220
    Animate $Toast.RenderTransform $P_Y 14 220 -Ease $EaseOut
})

function Show-Toast($text, $kind = 'ok') {
    $ToastText.Text = $text
    $ToastDot.Fill = Get-Brush $(switch ($kind) { 'error' { '#FF6B81' } 'info' { '#FFB547' } default { '#3DDC97' } })
    Animate $Toast $P_Opacity 1 200
    Animate $Toast.RenderTransform $P_Y 0 320 -From 20 -Ease $EaseBack
    $script:ToastTimer.Stop()
    $script:ToastTimer.Start()
}

# ---------------------------------------------------------------- cards
function Set-CardState($id) {
    $c = $script:Cards[$id]
    $p = Get-Project $id
    if (-not $c -or -not $p) { return }
    $running = $script:Running.ContainsKey($id)
    $exists = Test-ProjectFile $p

    if ($running) {
        $c.Dot.Fill = Get-Brush '#3DDC97'
        Animate $c.Dot $P_Opacity 0.3 750 -From 1 -Forever -Reverse
        $c.StatusText.Text = 'Running'
        $c.StatusText.Foreground = Get-Brush '#7FF0BE'
        $c.Root.BorderBrush = $FlameBrush
        Animate $c.Root.Effect $P_FxOpacity 0.8 1100 -From 0.3 -Ease $EaseSine -Forever -Reverse
        $c.RunBtn.Background = Get-Brush '#2EFF4D6D'
        $c.RunBtn.Foreground = Get-Brush '#FFA3B4'
        $c.RunGlyph.Text = [string][char]0xE71A
        $c.RunText.Text = 'Stop'
        $c.RunBtn.Opacity = 1
    } else {
        Stop-Animation $c.Dot $P_Opacity 1
        Stop-Animation $c.Root.Effect $P_FxOpacity 0
        $c.Dot.Fill = Get-Brush $(if ($exists) { '#6E6A8F' } else { '#FF6B81' })
        $c.StatusText.Text = $(if ($exists) { 'Ready' } else { 'File not found' })
        $c.StatusText.Foreground = Get-Brush $(if ($exists) { '#8F89B8' } else { '#FF8FA3' })
        $c.Root.BorderBrush = Get-Brush '#2B2654'
        $c.RunBtn.ClearValue($P_Bg)
        $c.RunBtn.ClearValue($P_Fg)
        $c.RunGlyph.Text = [string][char]0xE768
        $c.RunText.Text = 'Run'
        $c.RunBtn.Opacity = $(if ($exists) { 1 } else { 0.5 })
    }
}

function New-Card($p, $index) {
    $card = [System.Windows.Markup.XamlReader]::Parse($CardXaml)
    $c = @{ Root = $card }
    foreach ($n in 'Tile','Initial','TitleText','Dot','StatusText','FileText','DirText','RunBtn','RunGlyph','RunText','EditBtn','DelBtn') {
        $c[$n] = $card.FindName($n)
    }
    $pal = $TilePalette[$index % $TilePalette.Count]
    $c.Tile.Background = New-Object System.Windows.Media.LinearGradientBrush ((Get-Color $pal[0]), (Get-Color $pal[1]), 45.0)
    $c.Initial.Text = if ($p.Title) { [System.Globalization.StringInfo]::GetNextTextElement($p.Title).ToUpper() } else { '?' }
    $c.TitleText.Text = $p.Title
    $c.FileText.Text = [System.IO.Path]::GetFileName($p.Path)
    try { $c.DirText.Text = Split-Path -Parent $p.Path } catch { $c.DirText.Text = '' }
    $card.ToolTip = $p.Path
    $card.Tag = $p.Id
    foreach ($b in $c.RunBtn, $c.EditBtn, $c.DelBtn) { $b.Tag = $p.Id }

    $c.RunBtn.Add_Click({
        $p = Get-Project $this.Tag
        if (-not $p) { return }
        if ($script:Running.ContainsKey($p.Id)) { Stop-Project $p } else { Start-Project $p }
    })
    $c.EditBtn.Add_Click({ Show-Editor (Get-Project $this.Tag) })
    $c.DelBtn.Add_Click({ Show-DeleteConfirm (Get-Project $this.Tag) })

    $card.Add_MouseEnter({
        $s = $this.RenderTransform.Children[0]
        Animate $s $P_SX 1.025 160 -Ease $EaseOut
        Animate $s $P_SY 1.025 160 -Ease $EaseOut
        if (-not $script:Running.ContainsKey($this.Tag)) { $this.BorderBrush = Get-Brush '#4A3F86' }
    })
    $card.Add_MouseLeave({
        $s = $this.RenderTransform.Children[0]
        Animate $s $P_SX 1 200 -Ease $EaseOut
        Animate $s $P_SY 1 200 -Ease $EaseOut
        if (-not $script:Running.ContainsKey($this.Tag)) { $this.BorderBrush = Get-Brush '#2B2654' }
    })

    $script:Cards[$p.Id] = $c
    return $card
}

function Render-Cards($animate = '') {
    $CardList.Children.Clear()
    $script:Cards.Clear()
    $i = 0
    $stagger = 0
    foreach ($p in $script:Projects) {
        $card = New-Card $p $i
        [void]$CardList.Children.Add($card)
        $move = $card.RenderTransform.Children[1]
        if ($animate -eq '*' -or $animate -eq $p.Id) {
            Animate $card $P_Opacity 1 380 -From 0 -Delay ($stagger * 55)
            Animate $move $P_Y 0 480 -From 22 -Delay ($stagger * 55) -Ease $EaseOut
            $stagger++
        } else {
            $card.Opacity = 1
            $move.Y = 0
        }
        Set-CardState $p.Id
        $i++
    }
    Update-Counts
}

function Update-Counts {
    $n = $script:Projects.Count
    $r = $script:Running.Count
    if ($n -eq 0) {
        $CountText.Text = 'Nothing here yet'
        $EmptyState.Visibility = 'Visible'
        $Scroller.Visibility = 'Collapsed'
    } else {
        $dot = [string][char]0x00B7
        $CountText.Text = "$n project$(if ($n -ne 1) { 's' })" + $(if ($r -gt 0) { "   $dot   $r running" } else { '' })
        $EmptyState.Visibility = 'Collapsed'
        $Scroller.Visibility = 'Visible'
    }
}

# ---------------------------------------------------------------- run / stop
function Start-Project($p) {
    if (-not (Test-ProjectFile $p)) {
        Show-Toast "Command file not found. Edit the project to fix its path." 'error'
        return
    }
    $dir = Split-Path -Parent $p.Path
    $ext = [System.IO.Path]::GetExtension($p.Path).ToLower()
    $safeTitle = $p.Title -replace '[&|<>^"%]', ''
    try {
        if ($ext -eq '.ps1') {
            $proc = Start-Process powershell.exe -WorkingDirectory $dir -PassThru `
                -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$($p.Path)`"")
        } elseif ($ext -eq '.bat' -or $ext -eq '.cmd') {
            $proc = Start-Process cmd.exe -WorkingDirectory $dir -PassThru `
                -ArgumentList "/k title LocalRun - $safeTitle & `"$($p.Path)`""
        } else {
            Start-Process -FilePath $p.Path -WorkingDirectory $dir
            Show-Toast "Opened $($p.Title)"
            return
        }
        $script:Running[$p.Id] = $proc
        Set-CardState $p.Id
        Update-Counts
        $c = $script:Cards[$p.Id]
        if ($c) {
            $s = $c.Root.RenderTransform.Children[0]
            Animate $s $P_SX 1.06 140 -Reverse -Ease $EaseOut
            Animate $s $P_SY 1.06 140 -Reverse -Ease $EaseOut
        }
        Show-Toast "$($p.Title) is starting"
    } catch {
        Show-Toast "Could not start $($p.Title): $($_.Exception.Message)" 'error'
    }
}

function Stop-Project($p) {
    $proc = $script:Running[$p.Id]
    if ($proc -and -not $proc.HasExited) {
        # /T takes the whole tree down: the console plus the servers it started.
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
    }
    $script:Running.Remove($p.Id)
    Set-CardState $p.Id
    Update-Counts
    Show-Toast "$($p.Title) stopped" 'info'
}

# A project counts as running while its console window is open.
$procTimer = New-Object System.Windows.Threading.DispatcherTimer
$procTimer.Interval = [TimeSpan]::FromSeconds(1)
$procTimer.Add_Tick({
    foreach ($id in @($script:Running.Keys)) {
        if ($script:Running[$id].HasExited) {
            $script:Running.Remove($id)
            Set-CardState $id
            Update-Counts
            $p = Get-Project $id
            if ($p) { Show-Toast "$($p.Title) stopped" 'info' }
        }
    }
})

# ---------------------------------------------------------------- dialogs
function Open-Overlay($panel) {
    $EditPanel.Visibility = 'Collapsed'
    $ConfirmPanel.Visibility = 'Collapsed'
    $panel.Visibility = 'Visible'
    $script:OverlayOpen = $true
    $Overlay.Visibility = 'Visible'
    Animate $Overlay $P_Opacity 1 180
    Animate $Dialog.RenderTransform $P_SX 1 320 -From 0.92 -Ease $EaseBack
    Animate $Dialog.RenderTransform $P_SY 1 320 -From 0.92 -Ease $EaseBack
}

function Close-Overlay {
    $script:OverlayOpen = $false
    Animate $Dialog.RenderTransform $P_SX 0.95 150
    Animate $Dialog.RenderTransform $P_SY 0.95 150
    Animate $Overlay $P_Opacity 0 160 -OnDone { if (-not $script:OverlayOpen) { $Overlay.Visibility = 'Collapsed' } }
}

function Show-DialogError($text) {
    $DialogError.Text = $text
    $DialogError.Visibility = 'Visible'
}

function Show-Editor($p, $presetPath = '') {
    $script:EditingId = if ($p) { $p.Id } else { $null }
    $DialogTitle.Text = if ($p) { 'Edit project' } else { 'New project' }
    $BtnSave.Content = if ($p) { 'Save changes' } else { 'Add project' }
    $TxtTitle.Text = if ($p) { $p.Title } else { '' }
    $TxtPath.Text = if ($p) { $p.Path } else { $presetPath }
    if (-not $p -and $presetPath) { $TxtTitle.Text = Split-Path -Leaf (Split-Path -Parent $presetPath) }
    $DialogError.Visibility = 'Collapsed'
    $script:AllowMissing = $false
    Open-Overlay $EditPanel
    $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [action]{ $TxtTitle.Focus(); $TxtTitle.SelectAll() }) | Out-Null
}

function Save-Editor {
    $t = $TxtTitle.Text.Trim()
    $path = $TxtPath.Text.Trim().Trim('"')
    if (-not $t) { Show-DialogError 'Give the project a title.'; return }
    if (-not $path) { Show-DialogError 'Choose the command file that starts this project.'; return }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and -not $script:AllowMissing) {
        Show-DialogError "That file doesn't exist on this PC. Press save again to keep it anyway."
        $script:AllowMissing = $true
        return
    }
    if ($script:EditingId) {
        $p = Get-Project $script:EditingId
        $p.Title = $t
        $p.Path = $path
        $target = $p.Id
        $msg = "Saved $t"
    } else {
        $target = [guid]::NewGuid().ToString('N')
        [void]$script:Projects.Add([pscustomobject]@{ Id = $target; Title = $t; Path = $path })
        $msg = "Added $t"
    }
    Save-Projects
    Close-Overlay
    Render-Cards $target
    Show-Toast $msg
}

function Show-DeleteConfirm($p) {
    if (-not $p) { return }
    $script:DeletingId = $p.Id
    $ConfirmText.Text = "'$($p.Title)' will be removed from LocalRun. The command file itself is not touched."
    Open-Overlay $ConfirmPanel
}

function Confirm-Delete {
    Close-Overlay
    $c = $script:Cards[$script:DeletingId]
    if (-not $c) { return }
    $s = $c.Root.RenderTransform.Children[0]
    Animate $s $P_SX 0.85 200 -Ease $EaseOut
    Animate $s $P_SY 0.85 200 -Ease $EaseOut
    Animate $c.Root $P_Opacity 0 200 -OnDone {
        $p = Get-Project $script:DeletingId
        if ($p) {
            [void]$script:Projects.Remove($p)
            $script:Running.Remove($p.Id)
            Save-Projects
            Render-Cards
            Show-Toast "Removed $($p.Title)" 'info'
        }
        $script:DeletingId = $null
    }
}

# ---------------------------------------------------------------- wiring
$BtnNew.Add_Click({ Show-Editor $null })
$BtnEmptyAdd.Add_Click({ Show-Editor $null })
$BtnCancel.Add_Click({ Close-Overlay })
$BtnSave.Add_Click({ Save-Editor })
$BtnConfirmNo.Add_Click({ Close-Overlay })
$BtnConfirmYes.Add_Click({ Confirm-Delete })
$Overlay.Add_MouseLeftButtonDown({ param($s, $e) if ($e.OriginalSource -eq $Overlay) { Close-Overlay } })
$TxtPath.Add_TextChanged({ $script:AllowMissing = $false; $DialogError.Visibility = 'Collapsed' })
$TxtTitle.Add_TextChanged({ $DialogError.Visibility = 'Collapsed' })

$BtnBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose the command that starts this project'
    $dlg.Filter = 'Run commands (*.bat;*.cmd;*.ps1)|*.bat;*.cmd;*.ps1|All files (*.*)|*.*'
    $current = $TxtPath.Text.Trim().Trim('"')
    if ($current) {
        $folder = Split-Path -Parent $current -ErrorAction SilentlyContinue
        if ($folder -and (Test-Path -LiteralPath $folder)) { $dlg.InitialDirectory = $folder }
    }
    if ($dlg.ShowDialog($window)) {
        $TxtPath.Text = $dlg.FileName
        if (-not $TxtTitle.Text.Trim()) { $TxtTitle.Text = Split-Path -Leaf (Split-Path -Parent $dlg.FileName) }
    }
})

$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnMax.Add_Click({ $window.WindowState = $(if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
$BtnClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    $max = $window.WindowState -eq 'Maximized'
    # a chrome-less maximised window overhangs the screen by the resize border
    $Root.Margin = $(if ($max) { New-Object System.Windows.Thickness 7 } else { New-Object System.Windows.Thickness 0 })
    $BtnMax.Content = [string][char]$(if ($max) { 0xE923 } else { 0xE922 })
})

$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($script:OverlayOpen) {
        if ($e.Key -eq 'Escape') { Close-Overlay; $e.Handled = $true }
        elseif ($e.Key -eq 'Return') {
            if ($EditPanel.Visibility -eq 'Visible') { Save-Editor } else { Confirm-Delete }
            $e.Handled = $true
        }
    } elseif ($e.Key -eq 'N' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') {
        Show-Editor $null
        $e.Handled = $true
    }
})

$window.Add_DragOver({
    param($s, $e)
    if (-not $script:OverlayOpen -and $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $DropHint.Visibility = 'Visible'
        $e.Effects = 'Copy'
    } else { $e.Effects = 'None' }
    $e.Handled = $true
})
$window.Add_DragLeave({ $DropHint.Visibility = 'Collapsed' })
$window.Add_Drop({
    param($s, $e)
    $DropHint.Visibility = 'Collapsed'
    $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
    if ($files -and (Test-Path -LiteralPath $files[0] -PathType Leaf)) { Show-Editor $null $files[0] }
})

$window.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        $round = 2          # DWMWA_WINDOW_CORNER_PREFERENCE = round (Windows 11)
        [void][LocalRun.Dwm]::DwmSetWindowAttribute($h, 33, [ref]$round, 4)
        $border = 0x0054262B  # DWMWA_BORDER_COLOR, 0x00BBGGRR for #2B2654
        [void][LocalRun.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$border, 4)
    } catch {}
})

$window.Add_Loaded({
    Animate $Blob1.RenderTransform $P_X -70 9000 -Ease $EaseSine -Forever -Reverse
    Animate $Blob1.RenderTransform $P_Y 50 7000 -Ease $EaseSine -Forever -Reverse
    Animate $Blob2.RenderTransform $P_X 80 11000 -Ease $EaseSine -Forever -Reverse
    Animate $Blob2.RenderTransform $P_Y -60 8000 -Ease $EaseSine -Forever -Reverse
    Animate $Blob3.RenderTransform $P_X -90 10000 -Ease $EaseSine -Forever -Reverse
    Animate $EmptyArt.RenderTransform $P_Y -10 1600 -Ease $EaseSine -Forever -Reverse
    Render-Cards '*'
    $procTimer.Start()
})

$window.Add_Closed({ $procTimer.Stop(); $script:ToastTimer.Stop() })

Load-Projects
[void]$window.ShowDialog()
